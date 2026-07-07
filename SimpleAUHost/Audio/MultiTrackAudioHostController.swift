@preconcurrency import AudioToolbox
import AppKit
import CoreAudio
import Darwin
import Foundation

final class MultiTrackAudioHostController: @unchecked Sendable {
    private func recordDroppedFrames(_ frameCount: UInt32) {
        guard frameCount > 0 else { return }
        audioDropoutCounter.increment()
        droppedFrameCounter.add(UInt64(frameCount))
    }

    private func updateExpectedSampleTime(
        with inTimeStamp: UnsafePointer<AudioTimeStamp>?,
        frameCount: UInt32,
        expectedSampleTime: inout Double?
    ) {
        guard let inTimeStamp else { return }

        let sampleTimeValidRawValue: UInt32 = 1 << 0
        guard (inTimeStamp.pointee.mFlags.rawValue & sampleTimeValidRawValue) != 0 else {
            expectedSampleTime = nil
            return
        }

        let currentSampleTime = inTimeStamp.pointee.mSampleTime
        if let expectedSampleTime, currentSampleTime > expectedSampleTime + 0.5 {
            let missingFrames = UInt32((currentSampleTime - expectedSampleTime).rounded())
            recordDroppedFrames(missingFrames)
        }

        expectedSampleTime = currentSampleTime + Double(frameCount)
    }

    private var inputUnit: AudioUnit?
    private var outputUnit: AudioUnit?
    private var configuration: MultiTrackHostConfiguration?
    private var trackRuntimes: [TrackRuntime] = []
    private var bufferedTrackRuntimes: [TrackRuntime] = []
    private var broadcastTrackRuntimes: [TrackRuntime] = []
    private var realtimeTrackRuntimes: [TrackRuntime] = []
    private var bufferedWorkerShards: [BufferedTrackWorkerShard] = []
    private var captureBufferList: UnsafeMutableAudioBufferListPointer?
    private var captureChannelBuffers: [UnsafeMutablePointer<Float>] = []
    private var sharedStagedOutputBuffers: [FloatRingBuffer] = []
    private var stagedOutputScratchBuffers: [UnsafeMutablePointer<Float>] = []
    private var maxFramesPerSlice: UInt32 = 0
    private var callbackFrameCapacity: Int = 0
    private let audioDropoutCounter = AtomicCounter()
    private let droppedFrameCounter = AtomicCounter()
    private let peakInputCallbackFrames = AtomicCounter()
    private let peakOutputCallbackFrames = AtomicCounter()
    private let peakSharedInputRingOccupancyFrames = AtomicCounter()
    private let peakStagedOutputRingOccupancyFrames = AtomicCounter()
    /// Owned by the respective audio callback thread. Off-thread resets while
    /// the engine runs must go through the reset-request flags below instead of
    /// writing these directly (`start()`/`stop()` may write them because the IO
    /// units are not running at that point).
    private var nextExpectedInputSampleTime: Double?
    private var nextExpectedOutputSampleTime: Double?
    /// Non-zero requests that the next input/output callback clears its expected
    /// sample time; lets `resetDropoutCounters()` avoid racing the callbacks.
    private let inputSampleTimeResetRequested = AtomicCounter()
    private let outputSampleTimeResetRequested = AtomicCounter()
    private let priorityController = AudioHostingPriorityController()
    /// Guards `runtimeStatus` plus the runtime collections (`trackRuntimes`,
    /// `bufferedTrackRuntimes`, `broadcastTrackRuntimes`, `realtimeTrackRuntimes`,
    /// `bufferedWorkerShards`) and the ring-capacity fields read by
    /// `telemetrySnapshot()`, so the telemetry monitor task can read them safely
    /// while `start()`/`stop()` mutate them.
    /// IMPORTANT: never take this lock inside the audio callbacks or worker loops.
    /// They read the collections without locking, which is safe because the IO
    /// units and workers are stopped before `stop()` mutates the collections.
    private let runtimeStateLock = NSLock()
    private let lifecycleQueue = DispatchQueue(label: "SimpleAUHost.MultiTrackAudioHostController.lifecycle")
    private let deviceObserver = AudioHardwareChangeObserver()
    private let stagedOutputStateLock = NSLock()
    private let stagedOutputWakeup = AudioWorkerWakeup()
    private let stagedOutputExitGroup = DispatchGroup()
    private var runtimeStatus: String?
    /// Lock-free mirror of `runtimeStatus != nil` for the audio callbacks, which
    /// must not take `runtimeStateLock` (see the note on that lock). Non-zero
    /// means the runtime has been invalidated and callbacks should output silence.
    private let runtimeInvalidatedFlag = AtomicCounter()
    private var stagedOutputThread: Thread?
    private var shouldRunStagedOutputWorker = false
    private var stagedOutputPrimed = false
    private var stagedOutputPrerollFrames = 0
    private var inputRingCapacityFrames = 0
    private var peakTrackOutputRingCapacityFrames = 0
    private var stagedOutputRingCapacityFrames = 0
    @MainActor private var pluginEditorSessions: [String: HostedPluginEditorSession] = [:]
    @MainActor private var pluginEditorWindows: [String: PluginEditorWindowController] = [:]

    deinit {
        stop()
    }

    func start(configuration: MultiTrackHostConfiguration) throws {
        try lifecycleQueue.sync {
            try startOnLifecycleQueue(configuration: configuration)
        }
    }

    private func startOnLifecycleQueue(configuration: MultiTrackHostConfiguration) throws {
        stopOnLifecycleQueue()
        audioDropoutCounter.reset()
        droppedFrameCounter.reset()
        resetTelemetry()
        nextExpectedInputSampleTime = nil
        nextExpectedOutputSampleTime = nil
        inputSampleTimeResetRequested.reset()
        outputSampleTimeResetRequested.reset()
        clearRuntimeStatus()
        priorityController.activate(reason: "Low-latency audio hosting")

        do {
            let sampleRateDifference = abs(configuration.inputDevice.nominalSampleRate - configuration.outputDevice.nominalSampleRate)
            guard sampleRateDifference < 0.5 else {
                throw AudioHostError("Input and output sample rates must already match for multi track mode.")
            }

            try applyBufferSize(configuration.bufferSize, to: configuration.inputDevice.id)
            if configuration.outputDevice.id != configuration.inputDevice.id {
                try applyBufferSize(configuration.bufferSize, to: configuration.outputDevice.id)
            }

            self.configuration = configuration
            let maxInternalFrames = max(
                configuration.bufferSize,
                max(configuration.latencyBufferSettings.bufferedFrames, configuration.latencyBufferSettings.broadcastFrames)
            )
            maxFramesPerSlice = UInt32(suggestedMaximumFramesPerSlice(for: maxInternalFrames, nominalBufferSize: configuration.bufferSize))
            let maximumRenderFrames = allocatedFrameCapacity(
                actualMaximumFrames: Int(maxFramesPerSlice),
                nominalBufferSize: configuration.bufferSize
            )

            let availablePlugins = try AudioHostController().availablePlugins()

            let createdTrackRuntimes = try configuration.tracks.map { track in
                let resolvedPlugins = track.plugins.compactMap { insert in
                    insert.pluginID.flatMap { id in
                        availablePlugins.first { $0.id == id }.map { (insert, $0) }
                    }
                }
                return try TrackRuntime(
                    configuration: track,
                    plugins: resolvedPlugins,
                    sampleRate: configuration.inputDevice.nominalSampleRate,
                    hardwareBufferSize: configuration.bufferSize,
                    internalBufferFrames: configuration.latencyBufferSettings.internalFrames(
                        for: track.latencyClass,
                        hardwareBufferSize: configuration.bufferSize
                    ),
                    broadcastPrerollMultiplier: configuration.latencyBufferSettings.broadcastPrerollMultiplier,
                    maximumRenderFrames: maximumRenderFrames
                )
            }
            runtimeStateLock.lock()
            trackRuntimes = createdTrackRuntimes
            bufferedTrackRuntimes = createdTrackRuntimes.filter { $0.configuration.latencyClass == .buffered }
            broadcastTrackRuntimes = createdTrackRuntimes.filter { $0.configuration.latencyClass == .broadcast }
            realtimeTrackRuntimes = createdTrackRuntimes.filter(\.isRealtime)
            peakTrackOutputRingCapacityFrames = createdTrackRuntimes.reduce(0) { partialResult, runtime in
                max(partialResult, runtime.outputRingCapacityFrames)
            }
            runtimeStateLock.unlock()
            try prepareBufferedWorkerShards()

            try createAndConfigureIOUnits(for: configuration)
            let actualInputMaxFrames = try actualMaximumFramesPerSlice(for: inputUnit)
            let actualOutputMaxFrames = try actualMaximumFramesPerSlice(for: outputUnit)
            callbackFrameCapacity = min(
                maximumRenderFrames,
                allocatedFrameCapacity(
                    actualMaximumFrames: max(actualInputMaxFrames, actualOutputMaxFrames),
                    nominalBufferSize: configuration.bufferSize
                )
            )
            try prepareCaptureBuffers(
                inputChannelCount: configuration.inputDevice.inputChannelCount,
                frameCapacity: callbackFrameCapacity
            )
            try prepareStagedOutputBuffers(outputChannelCount: configuration.outputDevice.outputChannelCount)
            installDeviceObservers(for: configuration)
            if !bufferedTrackRuntimes.isEmpty || !broadcastTrackRuntimes.isEmpty {
                startStagedOutputWorker()
            }
            startBufferedWorkers()

            if let outputUnit {
                try checkStatus(AudioOutputUnitStart(outputUnit), "Failed to start multi-track output audio")
            }
            if let inputUnit {
                try checkStatus(AudioOutputUnitStart(inputUnit), "Failed to start multi-track input audio")
            }
        } catch {
            stopOnLifecycleQueue()
            throw error
        }
    }

    func audioDropoutCount() -> UInt64 {
        let controllerCount = audioDropoutCounter.load()
        return currentTrackRuntimes().reduce(controllerCount) { partialResult, runtime in
            partialResult + runtime.audioDropoutCount()
        }
    }

    func droppedFrameCount() -> UInt64 {
        let controllerCount = droppedFrameCounter.load()
        return currentTrackRuntimes().reduce(controllerCount) { partialResult, runtime in
            partialResult + runtime.droppedFrameCount()
        }
    }

    func resetDropoutCounters() {
        audioDropoutCounter.reset()
        droppedFrameCounter.reset()
        // The expected sample times are owned by the audio callback threads;
        // request the reset there instead of racing them from this thread.
        inputSampleTimeResetRequested.storeMax(1)
        outputSampleTimeResetRequested.storeMax(1)
        for runtime in currentTrackRuntimes() {
            runtime.resetDropoutCounters()
        }
    }

    func runtimeStatusMessage() -> String? {
        runtimeStateLock.lock()
        defer { runtimeStateLock.unlock() }
        return runtimeStatus
    }

    private struct RuntimeCollectionsSnapshot {
        let trackRuntimes: [TrackRuntime]
        let bufferedTrackRuntimes: [TrackRuntime]
        let broadcastTrackRuntimes: [TrackRuntime]
        let realtimeTrackRuntimes: [TrackRuntime]
        let bufferedWorkerShards: [BufferedTrackWorkerShard]
        let inputRingCapacityFrames: Int
        let peakTrackOutputRingCapacityFrames: Int
        let stagedOutputRingCapacityFrames: Int
    }

    private func runtimeCollectionsSnapshot() -> RuntimeCollectionsSnapshot {
        runtimeStateLock.lock()
        defer { runtimeStateLock.unlock() }
        return RuntimeCollectionsSnapshot(
            trackRuntimes: trackRuntimes,
            bufferedTrackRuntimes: bufferedTrackRuntimes,
            broadcastTrackRuntimes: broadcastTrackRuntimes,
            realtimeTrackRuntimes: realtimeTrackRuntimes,
            bufferedWorkerShards: bufferedWorkerShards,
            inputRingCapacityFrames: inputRingCapacityFrames,
            peakTrackOutputRingCapacityFrames: peakTrackOutputRingCapacityFrames,
            stagedOutputRingCapacityFrames: stagedOutputRingCapacityFrames
        )
    }

    private func currentTrackRuntimes() -> [TrackRuntime] {
        runtimeStateLock.lock()
        defer { runtimeStateLock.unlock() }
        return trackRuntimes
    }

    func telemetrySnapshot() -> AudioEngineTelemetrySnapshot {
        let snapshot = runtimeCollectionsSnapshot()
        let realtimeTelemetry = latencyTelemetrySnapshot(
            tracks: snapshot.realtimeTrackRuntimes,
            shards: []
        )
        let bufferedTelemetry = latencyTelemetrySnapshot(
            tracks: snapshot.bufferedTrackRuntimes,
            shards: snapshot.bufferedWorkerShards.filter { $0.latencyClass == .buffered }
        )
        let broadcastTelemetry = latencyTelemetrySnapshot(
            tracks: snapshot.broadcastTrackRuntimes,
            shards: snapshot.bufferedWorkerShards.filter { $0.latencyClass == .broadcast }
        )
        let peakTrackOutputOccupancy = snapshot.trackRuntimes.reduce(UInt64(0)) { partialResult, runtime in
            max(partialResult, runtime.peakOutputRingOccupancy())
        }
        let peakTrackInputOccupancy = snapshot.realtimeTrackRuntimes.reduce(UInt64(0)) { partialResult, runtime in
            max(partialResult, runtime.peakInputRingOccupancy())
        }
        let peakShardInputOccupancy = snapshot.bufferedWorkerShards.reduce(UInt64(0)) { partialResult, shard in
            max(partialResult, shard.peakInputRingOccupancy())
        }
        let peakTrackRenderDuration = snapshot.trackRuntimes.reduce(UInt64(0)) { partialResult, runtime in
            max(partialResult, runtime.peakRenderDurationMicros())
        }
        let peakShardRenderDuration = snapshot.bufferedWorkerShards.reduce(UInt64(0)) { partialResult, shard in
            max(partialResult, shard.peakRenderDurationMicros())
        }
        let averageTrackRenderDuration = averageMicros(
            totals: snapshot.trackRuntimes.map { $0.averageRenderDurationMicros() },
            count: snapshot.trackRuntimes.count
        )
        let averageShardRenderDuration = averageMicros(
            totals: snapshot.bufferedWorkerShards.map { $0.averageRenderDurationMicros() },
            count: snapshot.bufferedWorkerShards.count
        )
        let peakOutputOccupancy = max(peakTrackOutputOccupancy, peakStagedOutputRingOccupancyFrames.load())
        return AudioEngineTelemetrySnapshot(
            peakInputCallbackFrames: peakInputCallbackFrames.load(),
            peakOutputCallbackFrames: peakOutputCallbackFrames.load(),
            peakEffectRenderFrames: 0,
            peakInputRingOccupancyFrames: max(peakTrackInputOccupancy, max(peakShardInputOccupancy, peakSharedInputRingOccupancyFrames.load())),
            peakOutputRingOccupancyFrames: peakOutputOccupancy,
            inputRingCapacityFrames: snapshot.inputRingCapacityFrames,
            outputRingCapacityFrames: max(snapshot.peakTrackOutputRingCapacityFrames, snapshot.stagedOutputRingCapacityFrames),
            peakTrackRenderDurationMicros: peakTrackRenderDuration,
            averageTrackRenderDurationMicros: averageTrackRenderDuration,
            peakShardRenderDurationMicros: peakShardRenderDuration,
            averageShardRenderDurationMicros: averageShardRenderDuration,
            peakShardUtilizationPercent: snapshot.bufferedWorkerShards.reduce(0) { max($0, $1.peakUtilization()) },
            peakWorkerWakeupsPerSecond: snapshot.bufferedWorkerShards.reduce(0) { max($0, $1.peakWakeups()) },
            workerShardCount: snapshot.bufferedWorkerShards.count,
            realtime: realtimeTelemetry,
            buffered: bufferedTelemetry,
            broadcast: broadcastTelemetry
        )
    }

    func pluginStateSnapshot() -> [UUID: [UUID: Data]] {
        Dictionary(uniqueKeysWithValues: currentTrackRuntimes().compactMap { runtime in
            let states = runtime.serializedPluginStates()
            return states.isEmpty ? nil : (runtime.configuration.id, states)
        })
    }

    func trackPluginLatencySnapshot() -> [TrackPluginLatencySnapshot] {
        currentTrackRuntimes().map { runtime in
            TrackPluginLatencySnapshot(
                trackID: runtime.configuration.id,
                pluginLatencyFrames: runtime.pluginLatencyFrames()
            )
        }
    }

    func applyPluginStates(
        for trackID: UUID,
        statesByInsertID: [UUID: Data]
    ) throws -> [UUID: String] {
        guard let runtime = currentTrackRuntimes().first(where: { $0.configuration.id == trackID }) else {
            throw AudioHostError("This track is not loaded on the running engine.")
        }
        return runtime.applySerializedPluginStates(statesByInsertID)
    }

    func setWavesTuneRealtimeBypassed(_ isBypassed: Bool) throws -> Int {
        guard configuration != nil else {
            throw AudioHostError("Start the engine before changing Waves Tune bypass.")
        }

        return try currentTrackRuntimes().reduce(into: 0) { count, runtime in
            count += try runtime.setWavesTuneRealtimeBypassed(isBypassed)
        }
    }

    func applyWavesTuneRealtimeKeySelection(_ selection: WavesTuneKeySelection) throws -> Int {
        guard configuration != nil else {
            throw AudioHostError("Start the engine before applying Waves Tune settings.")
        }

        let normalizedSelection = selection.normalized
        return try currentTrackRuntimes().reduce(into: 0) { count, runtime in
            count += try runtime.applyWavesTuneRealtimeKeySelection(normalizedSelection)
        }
    }

    func applyWavesTuneRealtimeStrength(
        _ strength: WavesTuneStrengthPreset,
        to trackID: UUID
    ) throws -> Int {
        guard configuration != nil else {
            throw AudioHostError("Start the engine before applying Waves Tune strength.")
        }

        guard let runtime = currentTrackRuntimes().first(where: { $0.configuration.id == trackID }) else {
            throw AudioHostError("This track is not loaded on the running engine.")
        }

        return try runtime.applyWavesTuneRealtimeStrength(strength)
    }

    func currentWavesTuneRealtimeStrengthPreset(
        for trackID: UUID
    ) throws -> WavesTuneStrengthPreset? {
        guard configuration != nil else {
            throw AudioHostError("Start the engine before reading Waves Tune strength.")
        }

        guard let runtime = currentTrackRuntimes().first(where: { $0.configuration.id == trackID }) else {
            throw AudioHostError("This track is not loaded on the running engine.")
        }

        return try runtime.currentWavesTuneRealtimeStrengthPreset()
    }

    func beginStop() {
        lifecycleQueue.sync {
            beginStopOnLifecycleQueue()
        }
    }

    func joinStopped() {
        lifecycleQueue.sync {
            joinStoppedOnLifecycleQueue()
        }
    }

    func stop() {
        lifecycleQueue.sync {
            stopOnLifecycleQueue()
        }
    }

    private func stopOnLifecycleQueue() {
        beginStopOnLifecycleQueue()
        joinStoppedOnLifecycleQueue()
    }

    private func beginStopOnLifecycleQueue() {
        requestBufferedWorkersStop()
        requestStagedOutputWorkerStop()
        deviceObserver.stop()
        if let inputUnit {
            AudioOutputUnitStop(inputUnit)
        }
        if let outputUnit {
            AudioOutputUnitStop(outputUnit)
        }

        if let inputUnit {
            AudioUnitUninitialize(inputUnit)
            AudioComponentInstanceDispose(inputUnit)
        }
        if let outputUnit {
            AudioUnitUninitialize(outputUnit)
            AudioComponentInstanceDispose(outputUnit)
        }

        inputUnit = nil
        outputUnit = nil
    }

    private func joinStoppedOnLifecycleQueue() {
        joinBufferedWorkers()
        joinStagedOutputWorker()

        // Retire the runtime collections under the lock so concurrent readers
        // (e.g. the telemetry monitor task) never observe a mid-mutation array.
        // The local copies keep the runtimes alive until the end of this scope;
        // their deinits dispose the plugin Audio Units and free the ring buffers.
        runtimeStateLock.lock()
        let retiredTrackRuntimes = trackRuntimes
        let retiredWorkerShards = bufferedWorkerShards
        trackRuntimes = []
        bufferedTrackRuntimes = []
        broadcastTrackRuntimes = []
        realtimeTrackRuntimes = []
        bufferedWorkerShards = []
        inputRingCapacityFrames = 0
        peakTrackOutputRingCapacityFrames = 0
        stagedOutputRingCapacityFrames = 0
        runtimeStateLock.unlock()

        sharedStagedOutputBuffers.removeAll()

        for pointer in captureChannelBuffers {
            pointer.deallocate()
        }
        captureChannelBuffers.removeAll()
        for pointer in stagedOutputScratchBuffers {
            pointer.deallocate()
        }
        stagedOutputScratchBuffers.removeAll()
        captureBufferList?.unsafeMutablePointer.deallocate()
        captureBufferList = nil

        configuration = nil
        maxFramesPerSlice = 0
        callbackFrameCapacity = 0
        stagedOutputPrerollFrames = 0
        nextExpectedInputSampleTime = nil
        nextExpectedOutputSampleTime = nil
        clearRuntimeStatus()
        priorityController.deactivate()
        withExtendedLifetime(retiredTrackRuntimes) {}
        withExtendedLifetime(retiredWorkerShards) {}
    }

    @MainActor
    func openPluginEditor(for trackID: UUID, pluginID: UUID? = nil) async throws {
        guard let runtime = currentTrackRuntimes().first(where: { $0.configuration.id == trackID }) else {
            throw AudioHostError("Start the engine before opening a plugin editor.")
        }
        guard runtime.hasOpenablePluginEditor else {
            throw AudioHostError("This track does not have a plugin loaded.")
        }

        let editorKey = pluginEditorKey(trackID: trackID, pluginID: pluginID)

        if let existingWindow = pluginEditorWindows[editorKey] {
            existingWindow.showWindow(nil)
            existingWindow.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let editorSession = try await runtime.makePluginEditorSession(pluginID: pluginID)
        let windowController = PluginEditorWindowController(
            trackID: trackID,
            title: runtime.configuration.name,
            contentViewController: editorSession.viewController
        )
        windowController.onClose = { [weak self] in
            Task { @MainActor in
                editorSession.invalidate()
                self?.pluginEditorSessions.removeValue(forKey: editorKey)
                self?.pluginEditorWindows.removeValue(forKey: editorKey)
            }
        }
        pluginEditorSessions[editorKey] = editorSession
        pluginEditorWindows[editorKey] = windowController
        windowController.showWindow(nil)
        windowController.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @MainActor
    func makeHostedPluginEditorSession(for trackID: UUID, pluginID: UUID? = nil) async throws -> HostedPluginEditorSession {
        guard let runtime = currentTrackRuntimes().first(where: { $0.configuration.id == trackID }) else {
            throw AudioHostError("Start the engine before opening a plugin editor.")
        }
        guard runtime.hasOpenablePluginEditor else {
            throw AudioHostError("This track does not have a plugin loaded.")
        }

        return try await runtime.makePluginEditorSession(pluginID: pluginID)
    }

    private func pluginEditorKey(trackID: UUID, pluginID: UUID?) -> String {
        if let pluginID {
            return "\(trackID.uuidString)::\(pluginID.uuidString)"
        }
        return "\(trackID.uuidString)::first"
    }

    private func prepareCaptureBuffers(inputChannelCount: Int, frameCapacity: Int) throws {
        captureBufferList?.unsafeMutablePointer.deallocate()
        captureBufferList = nil
        for pointer in captureChannelBuffers {
            pointer.deallocate()
        }
        captureChannelBuffers.removeAll()

        guard frameCapacity > 0 else {
            throw AudioHostError("Failed to determine the input capture buffer capacity.")
        }

        captureBufferList = AudioBufferList.allocate(maximumBuffers: inputChannelCount)
        captureBufferList?.count = inputChannelCount

        for channelIndex in 0..<inputChannelCount {
            let pointer = UnsafeMutablePointer<Float>.allocate(capacity: frameCapacity)
            captureChannelBuffers.append(pointer)
            captureBufferList?[channelIndex].mNumberChannels = 1
            captureBufferList?[channelIndex].mDataByteSize = UInt32(frameCapacity * MemoryLayout<Float>.size)
            captureBufferList?[channelIndex].mData = UnsafeMutableRawPointer(pointer)
        }
    }

    private func prepareStagedOutputBuffers(outputChannelCount: Int) throws {
        for pointer in stagedOutputScratchBuffers {
            pointer.deallocate()
        }
        stagedOutputScratchBuffers.removeAll()
        sharedStagedOutputBuffers.removeAll()
        stagedOutputPrimed = false
        stagedOutputPrerollFrames = 0
        runtimeStateLock.lock()
        stagedOutputRingCapacityFrames = 0
        runtimeStateLock.unlock()

        guard let configuration else { return }
        let maxProcessingFrames = maxNonRealtimeProcessingFrames()
        let processingPrerollFrames = broadcastTrackRuntimes.isEmpty
            ? maxProcessingFrames
            : maxProcessingFrames * max(1, configuration.latencyBufferSettings.broadcastPrerollMultiplier)
        stagedOutputPrerollFrames = max(
            configuration.bufferSize * 2,
            processingPrerollFrames
        )
        let ringCapacityFrames = max(
            4096,
            max(configuration.bufferSize * 32, stagedOutputPrerollFrames * 2)
        )
        let ringCapacity = UInt32(min(ringCapacityFrames, Int(UInt32.max)))

        var newStagedOutputRingCapacityFrames = 0
        for _ in 0..<outputChannelCount {
            let buffer = FloatRingBuffer()
            guard buffer.initialize(minimumCapacity: ringCapacity) else {
                throw AudioHostError("Failed to allocate staged output buffer.")
            }
            sharedStagedOutputBuffers.append(buffer)
            stagedOutputScratchBuffers.append(UnsafeMutablePointer<Float>.allocate(capacity: configuration.bufferSize))
            newStagedOutputRingCapacityFrames = max(newStagedOutputRingCapacityFrames, Int(buffer.capacity))
        }
        runtimeStateLock.lock()
        stagedOutputRingCapacityFrames = newStagedOutputRingCapacityFrames
        runtimeStateLock.unlock()
    }

    private func createAndConfigureIOUnits(for configuration: MultiTrackHostConfiguration) throws {
        inputUnit = try createHALOutputUnit()
        outputUnit = try createHALOutputUnit()

        guard let inputUnit, let outputUnit else {
            throw AudioHostError("Failed to create Core Audio I/O units for multi track mode.")
        }

        var enableIO: UInt32 = 1
        var disableIO: UInt32 = 0
        var currentInputDevice = configuration.inputDevice.id
        var currentOutputDevice = configuration.outputDevice.id
        var inputFormat = streamFormat(channels: UInt32(configuration.inputDevice.inputChannelCount), sampleRate: configuration.inputDevice.nominalSampleRate)
        var outputFormat = streamFormat(channels: UInt32(configuration.outputDevice.outputChannelCount), sampleRate: configuration.outputDevice.nominalSampleRate)
        var inputCallback = AURenderCallbackStruct(inputProc: Self.inputCallback, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        var outputCallback = AURenderCallbackStruct(inputProc: Self.outputCallback, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        var maxFrames = maxFramesPerSlice

        try checkStatus(
            AudioUnitSetProperty(inputUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enableIO, UInt32(MemoryLayout<UInt32>.size)),
            "Failed to enable multi-track input on AUHAL"
        )
        try checkStatus(
            AudioUnitSetProperty(inputUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &disableIO, UInt32(MemoryLayout<UInt32>.size)),
            "Failed to disable multi-track output on input AUHAL"
        )
        try checkStatus(
            AudioUnitSetProperty(inputUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &currentInputDevice, UInt32(MemoryLayout<AudioDeviceID>.size)),
            "Failed to select multi-track input device"
        )
        try checkStatus(
            AudioUnitSetProperty(
                inputUnit,
                kAudioOutputUnitProperty_SetInputCallback,
                kAudioUnitScope_Global,
                0,
                &inputCallback,
                UInt32(MemoryLayout<AURenderCallbackStruct>.size)
            ),
            "Failed to install multi-track input callback"
        )
        try checkStatus(
            AudioUnitSetProperty(inputUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &inputFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)),
            "Failed to set multi-track input stream format"
        )
        try checkStatus(
            AudioUnitSetProperty(inputUnit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFrames, UInt32(MemoryLayout<UInt32>.size)),
            "Failed to set multi-track input maximum frames"
        )
        try checkStatus(AudioUnitInitialize(inputUnit), "Failed to initialize multi-track input AUHAL")

        try checkStatus(
            AudioUnitSetProperty(outputUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &enableIO, UInt32(MemoryLayout<UInt32>.size)),
            "Failed to enable multi-track output on AUHAL"
        )
        try checkStatus(
            AudioUnitSetProperty(outputUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &disableIO, UInt32(MemoryLayout<UInt32>.size)),
            "Failed to disable multi-track input on output AUHAL"
        )
        try checkStatus(
            AudioUnitSetProperty(outputUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &currentOutputDevice, UInt32(MemoryLayout<AudioDeviceID>.size)),
            "Failed to select multi-track output device"
        )
        try checkStatus(
            AudioUnitSetProperty(outputUnit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &outputCallback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)),
            "Failed to install multi-track output callback"
        )
        try checkStatus(
            AudioUnitSetProperty(outputUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &outputFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)),
            "Failed to set multi-track output stream format"
        )
        try checkStatus(
            AudioUnitSetProperty(outputUnit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFrames, UInt32(MemoryLayout<UInt32>.size)),
            "Failed to set multi-track output maximum frames"
        )
        try checkStatus(AudioUnitInitialize(outputUnit), "Failed to initialize multi-track output AUHAL")
    }

    private func createHALOutputUnit() throws -> AudioUnit {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )

        guard let component = AudioComponentFindNext(nil, &description) else {
            throw AudioHostError("Could not find the system AUHAL component.")
        }

        var createdUnit: AudioComponentInstance?
        try checkStatus(AudioComponentInstanceNew(component, &createdUnit), "Failed to create AUHAL instance")

        guard let createdUnit else {
            throw AudioHostError("AUHAL creation returned no instance.")
        }

        return createdUnit
    }

    private func applyBufferSize(_ bufferSize: Int, to deviceID: AudioDeviceID) throws {
        var requestedSize = UInt32(bufferSize)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        try checkStatus(
            AudioObjectSetPropertyData(
                deviceID,
                &address,
                0,
                nil,
                UInt32(MemoryLayout<UInt32>.size),
                &requestedSize
            ),
            "Failed to apply the requested multi-track buffer size"
        )
    }

    private func streamFormat(channels: UInt32, sampleRate: Double) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: UInt32(MemoryLayout<Float>.size),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(MemoryLayout<Float>.size),
            mChannelsPerFrame: channels,
            mBitsPerChannel: 32,
            mReserved: 0
        )
    }

    private static let inputCallback: AURenderCallback = { inRefCon, ioActionFlags, inTimeStamp, _, inNumberFrames, _ in
        let controller = Unmanaged<MultiTrackAudioHostController>.fromOpaque(inRefCon).takeUnretainedValue()
        return controller.handleInputCallback(ioActionFlags: ioActionFlags, inTimeStamp: inTimeStamp, inNumberFrames: inNumberFrames)
    }

    private static let outputCallback: AURenderCallback = { inRefCon, _, inTimeStamp, _, inNumberFrames, ioData in
        let controller = Unmanaged<MultiTrackAudioHostController>.fromOpaque(inRefCon).takeUnretainedValue()
        return controller.handleOutputCallback(inTimeStamp: inTimeStamp, inNumberFrames: inNumberFrames, ioData: ioData)
    }

    private func handleInputCallback(
        ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>?,
        inTimeStamp: UnsafePointer<AudioTimeStamp>?,
        inNumberFrames: UInt32
    ) -> OSStatus {
        guard let inputUnit, let captureBufferList else { return noErr }
        if let status = statusForInvalidCallbackFrameCount(Int(inNumberFrames)) {
            return status
        }
        if runtimeInvalidatedFlag.load() != 0 {
            return noErr
        }
        peakInputCallbackFrames.storeMax(UInt64(inNumberFrames))
        if inputSampleTimeResetRequested.load() != 0 {
            inputSampleTimeResetRequested.reset()
            nextExpectedInputSampleTime = nil
        }
        updateExpectedSampleTime(
            with: inTimeStamp,
            frameCount: inNumberFrames,
            expectedSampleTime: &nextExpectedInputSampleTime
        )

        for index in 0..<captureBufferList.count {
            captureBufferList[index].mDataByteSize = inNumberFrames * UInt32(MemoryLayout<Float>.size)
        }

        var renderFlags = ioActionFlags?.pointee ?? []
        var timeStamp = inTimeStamp?.pointee ?? AudioTimeStamp()
        let status = AudioUnitRender(
            inputUnit,
            &renderFlags,
            &timeStamp,
            1,
            inNumberFrames,
            captureBufferList.unsafeMutablePointer
        )
        if status != noErr {
            recordDroppedFrames(inNumberFrames)
            return status
        }

        for runtime in realtimeTrackRuntimes {
            let inputStart = runtime.inputStartChannelOffset
            guard inputStart < captureBufferList.count,
                  let source1 = captureBufferList[inputStart].mData?.assumingMemoryBound(to: Float.self) else {
                recordDroppedFrames(inNumberFrames)
                continue
            }
            let source2 = runtime.configuration.channelCount == 2 && inputStart + 1 < captureBufferList.count
                ? captureBufferList[inputStart + 1].mData?.assumingMemoryBound(to: Float.self)
                : nil
            runtime.enqueueRealtimeInput(source1: source1, source2: source2, frameCount: inNumberFrames)
        }

        for shard in bufferedWorkerShards {
            shard.enqueueInput(from: captureBufferList, frameCount: inNumberFrames)
        }
        signalBufferedWorkers()

        return noErr
    }

    private func handleOutputCallback(
        inTimeStamp: UnsafePointer<AudioTimeStamp>?,
        inNumberFrames: UInt32,
        ioData: UnsafeMutablePointer<AudioBufferList>?
    ) -> OSStatus {
        guard let ioData else { return noErr }
        let frameCount = Int(inNumberFrames)
        let bytes = UInt32(frameCount * MemoryLayout<Float>.size)
        let outputBuffers = UnsafeMutableAudioBufferListPointer(ioData)
        for bufferIndex in 0..<outputBuffers.count {
            outputBuffers[bufferIndex].mDataByteSize = bytes
            if let destination = outputBuffers[bufferIndex].mData?.assumingMemoryBound(to: Float.self) {
                clearAudioBuffer(destination, frameCount: frameCount)
            }
        }
        if let status = statusForInvalidCallbackFrameCount(frameCount) {
            return status
        }
        if runtimeInvalidatedFlag.load() != 0 {
            return noErr
        }
        peakOutputCallbackFrames.storeMax(UInt64(inNumberFrames))
        if outputSampleTimeResetRequested.load() != 0 {
            outputSampleTimeResetRequested.reset()
            nextExpectedOutputSampleTime = nil
        }
        updateExpectedSampleTime(
            with: inTimeStamp,
            frameCount: inNumberFrames,
            expectedSampleTime: &nextExpectedOutputSampleTime
        )

        drainStagedOutput(into: outputBuffers, frameCount: frameCount)

        for runtime in realtimeTrackRuntimes {
            runtime.mixRealtimeOutput(into: outputBuffers, hardwareFrames: frameCount)
        }
        stagedOutputWakeup.signal()
        signalBufferedWorkers()

        return noErr
    }

    @MainActor
    func closePluginEditorWindows() {
        closePluginEditorWindowsOnMainActor()
    }
}

private extension MultiTrackAudioHostController {
    func prepareBufferedWorkerShards() throws {
        stopBufferedWorkers()
        runtimeStateLock.lock()
        bufferedWorkerShards = []
        runtimeStateLock.unlock()
        var newInputRingCapacityFrames = realtimeTrackRuntimes.reduce(0) { max($0, $1.outputRingCapacityFrames) }

        let bufferedShards = try makeBufferedWorkerShards(
            tracks: bufferedTrackRuntimes,
            latencyClass: .buffered,
            suggestedCount: suggestedWorkerShardCount(for: .buffered, trackCount: bufferedTrackRuntimes.count)
        )
        let broadcastShards = try makeBufferedWorkerShards(
            tracks: broadcastTrackRuntimes,
            latencyClass: .broadcast,
            suggestedCount: suggestedWorkerShardCount(for: .broadcast, trackCount: broadcastTrackRuntimes.count)
        )
        let newShards = bufferedShards + broadcastShards
        newInputRingCapacityFrames = newShards.reduce(newInputRingCapacityFrames) { max($0, $1.inputRingCapacityFrames) }

        runtimeStateLock.lock()
        bufferedWorkerShards = newShards
        inputRingCapacityFrames = newInputRingCapacityFrames
        runtimeStateLock.unlock()
    }

    private func makeBufferedWorkerShards(
        tracks: [TrackRuntime],
        latencyClass: TrackLatencyClass,
        suggestedCount: Int
    ) throws -> [BufferedTrackWorkerShard] {
        guard !tracks.isEmpty else { return [] }

        let shardCount = max(1, min(suggestedCount, tracks.count))
        var buckets = Array(repeating: [TrackRuntime](), count: shardCount)
        var bucketLoads = Array(repeating: 0, count: shardCount)

        for runtime in tracks.sorted(by: { $0.estimatedLoadWeight() > $1.estimatedLoadWeight() }) {
            let lightestIndex = bucketLoads.enumerated().min(by: { $0.element < $1.element })?.offset ?? 0
            buckets[lightestIndex].append(runtime)
            bucketLoads[lightestIndex] += runtime.estimatedLoadWeight()
        }

        return try buckets.enumerated().compactMap { index, runtimes in
            guard !runtimes.isEmpty else { return nil }
            return try BufferedTrackWorkerShard(
                id: index,
                latencyClass: latencyClass,
                tracks: runtimes,
                recordDroppedFrames: { [weak self] in self?.recordDroppedFrames($0) },
                signalStagedOutput: { [weak self] in self?.stagedOutputWakeup.signal() },
                runtimeStatusMessage: { [weak self] in self?.runtimeStatusMessage() }
            )
        }
    }

    func startBufferedWorkers() {
        let affinityBase: Int32 = 11
        for (index, shard) in bufferedWorkerShards.enumerated() {
            shard.startWorker(affinityTag: affinityBase + Int32(index))
        }
    }

    func requestBufferedWorkersStop() {
        for shard in bufferedWorkerShards {
            shard.requestStop()
        }
    }

    func joinBufferedWorkers() {
        for shard in bufferedWorkerShards {
            shard.joinStopped()
        }
    }

    func stopBufferedWorkers() {
        requestBufferedWorkersStop()
        joinBufferedWorkers()
    }

    func signalBufferedWorkers() {
        for shard in bufferedWorkerShards {
            shard.signalWorkAvailable()
        }
    }

    func startStagedOutputWorker() {
        stagedOutputStateLock.lock()
        shouldRunStagedOutputWorker = true
        stagedOutputStateLock.unlock()
        stagedOutputExitGroup.enter()

        let stagedOutputThread = Thread { [weak self] in
            defer {
                self?.stagedOutputExitGroup.leave()
            }
            self?.stagedOutputWorkerLoop()
        }
        stagedOutputThread.name = "SimpleAUHost.MultiTrackStagedOutput"
        stagedOutputThread.qualityOfService = .userInteractive
        self.stagedOutputThread = stagedOutputThread
        stagedOutputThread.start()
    }

    func requestStagedOutputWorkerStop() {
        stagedOutputStateLock.lock()
        shouldRunStagedOutputWorker = false
        stagedOutputStateLock.unlock()

        // See `BufferedTrackWorkerShard.requestStop()` for the shutdown invariant:
        // the wakeup signal (not `cancel()`) unblocks a parked worker, and the
        // loop re-checks its run flag after every wait.
        stagedOutputThread?.cancel()
        stagedOutputWakeup.signal()
    }

    func joinStagedOutputWorker() {
        if stagedOutputThread != nil {
            if stagedOutputExitGroup.wait(timeout: .now() + .seconds(5)) == .timedOut {
                NSLog("SimpleAUHost: staged output worker did not exit within 5 seconds; continuing to wait.")
                assertionFailure("Staged output worker failed to stop in time")
                stagedOutputExitGroup.wait()
            }
        }
        stagedOutputThread = nil
    }

    func stopStagedOutputWorker() {
        requestStagedOutputWorkerStop()
        joinStagedOutputWorker()
    }

    func shouldStagedOutputWorkerContinue() -> Bool {
        stagedOutputStateLock.lock()
        defer { stagedOutputStateLock.unlock() }
        return shouldRunStagedOutputWorker
    }

    func stagedOutputWorkerLoop() {
        guard let configuration, !(bufferedTrackRuntimes.isEmpty && broadcastTrackRuntimes.isEmpty) else { return }
        promoteCurrentThreadToAudioWorkerQoS(QOS_CLASS_USER_INTERACTIVE)
        let frames = configuration.bufferSize

        while shouldStagedOutputWorkerContinue() && !Thread.current.isCancelled {
            // Permanent exit: a non-nil runtime status means the engine was
            // invalidated (e.g. device change) and must be restarted.
            if runtimeStatusMessage() != nil {
                return
            }

            let hasRingSpace = sharedStagedOutputBuffers.allSatisfy {
                $0.availableWrite() >= UInt32(frames)
            }
            let hasTrackOutput = canStageNonRealtimeOutput(frames: frames)

            guard hasRingSpace, hasTrackOutput else {
                stagedOutputWakeup.wait()
                continue
            }

            for pointer in stagedOutputScratchBuffers {
                clearAudioBuffer(pointer, frameCount: frames)
            }

            stageNonRealtimeOutput(into: stagedOutputScratchBuffers, frames: frames)

            for (index, buffer) in sharedStagedOutputBuffers.enumerated() {
                let writtenFrames = buffer.write(from: stagedOutputScratchBuffers[index], count: UInt32(frames))
                peakStagedOutputRingOccupancyFrames.storeMax(UInt64(buffer.availableRead()))
                if writtenFrames < UInt32(frames) {
                    recordDroppedFrames(UInt32(frames) - writtenFrames)
                }
            }
            signalBufferedWorkers()
        }
    }

    func drainStagedOutput(into outputBuffers: UnsafeMutableAudioBufferListPointer, frameCount: Int) {
        guard !sharedStagedOutputBuffers.isEmpty else { return }
        let requestedFrames = UInt32(frameCount)
        let prerollFrames = UInt32(max(stagedOutputPrerollFrames, frameCount * 2))
        let minAvailable = sharedStagedOutputBuffers.reduce(UInt32.max) { partialResult, buffer in
            min(partialResult, buffer.availableRead())
        }

        if !stagedOutputPrimed {
            guard minAvailable >= prerollFrames else {
                return
            }
            stagedOutputPrimed = true
        }

        guard minAvailable >= requestedFrames else {
            stagedOutputPrimed = false
            recordDroppedFrames(requestedFrames - minAvailable)
            return
        }

        var droppedFrames: UInt32 = 0
        for index in 0..<min(outputBuffers.count, sharedStagedOutputBuffers.count) {
            guard let destination = outputBuffers[index].mData?.assumingMemoryBound(to: Float.self) else {
                continue
            }
            let readFrames = sharedStagedOutputBuffers[index].read(into: destination, count: requestedFrames)
            peakStagedOutputRingOccupancyFrames.storeMax(UInt64(sharedStagedOutputBuffers[index].availableRead()))
            if readFrames < requestedFrames {
                droppedFrames = max(droppedFrames, requestedFrames - readFrames)
                destination.advanced(by: Int(readFrames)).update(repeating: 0, count: frameCount - Int(readFrames))
            }
        }

        if droppedFrames > 0 {
            stagedOutputPrimed = false
            recordDroppedFrames(droppedFrames)
        }
    }

    func maxNonRealtimeProcessingFrames() -> Int {
        var maxFrames = 0
        for runtime in bufferedTrackRuntimes {
            maxFrames = max(maxFrames, runtime.processingFrames)
        }
        for runtime in broadcastTrackRuntimes {
            maxFrames = max(maxFrames, runtime.processingFrames)
        }
        return maxFrames
    }

    func canStageNonRealtimeOutput(frames: Int) -> Bool {
        for runtime in bufferedTrackRuntimes where !runtime.hasBufferedOutput(frames: frames) {
            return false
        }
        for runtime in broadcastTrackRuntimes where !runtime.hasBufferedOutput(frames: frames) {
            return false
        }
        return !bufferedTrackRuntimes.isEmpty || !broadcastTrackRuntimes.isEmpty
    }

    func stageNonRealtimeOutput(
        into stagedOutputBuffers: [UnsafeMutablePointer<Float>],
        frames: Int
    ) {
        for runtime in bufferedTrackRuntimes {
            runtime.stageBufferedOutput(into: stagedOutputBuffers, frames: frames)
        }
        for runtime in broadcastTrackRuntimes {
            runtime.stageBufferedOutput(into: stagedOutputBuffers, frames: frames)
        }
    }

    func resetTelemetry() {
        peakInputCallbackFrames.reset()
        peakOutputCallbackFrames.reset()
        peakSharedInputRingOccupancyFrames.reset()
        peakStagedOutputRingOccupancyFrames.reset()
        let snapshot = runtimeCollectionsSnapshot()
        for runtime in snapshot.trackRuntimes {
            runtime.resetTelemetry()
        }
        for shard in snapshot.bufferedWorkerShards {
            shard.resetTelemetry()
        }
    }

    func suggestedWorkerShardCount(for latencyClass: TrackLatencyClass, trackCount: Int) -> Int {
        guard trackCount > 0 else { return 0 }
        let performanceCores = max(1, estimatedPerformanceCoreCount())
        switch latencyClass {
        case .realtime:
            return 0
        case .buffered:
            return min(trackCount, max(1, performanceCores - (broadcastTrackRuntimes.isEmpty ? 0 : 1)))
        case .broadcast:
            return min(trackCount, max(1, performanceCores / 2))
        }
    }

    func actualMaximumFramesPerSlice(for unit: AudioUnit?) throws -> Int {
        guard let unit else { return 0 }
        var frames: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        try checkStatus(
            AudioUnitGetProperty(
                unit,
                kAudioUnitProperty_MaximumFramesPerSlice,
                kAudioUnitScope_Global,
                0,
                &frames,
                &dataSize
            ),
            "Failed to query multi-track maximum frames per slice"
        )
        return Int(frames)
    }

    func installDeviceObservers(for configuration: MultiTrackHostConfiguration) {
        var observedDevices = [configuration.inputDevice.id]
        if configuration.outputDevice.id != configuration.inputDevice.id {
            observedDevices.append(configuration.outputDevice.id)
        }

        deviceObserver.startMonitoring(deviceIDs: observedDevices) { [weak self] message in
            self?.invalidateRuntime(message)
        }
    }

    func invalidateRuntime(_ message: String) {
        runtimeStateLock.lock()
        if runtimeStatus == nil {
            runtimeStatus = message
        }
        runtimeStateLock.unlock()
        runtimeInvalidatedFlag.storeMax(1)
        signalBufferedWorkers()
        stagedOutputWakeup.signal()
    }

    func clearRuntimeStatus() {
        runtimeStateLock.lock()
        runtimeStatus = nil
        runtimeStateLock.unlock()
        runtimeInvalidatedFlag.reset()
    }

    func statusForInvalidCallbackFrameCount(_ frameCount: Int) -> OSStatus? {
        guard frameCount > callbackFrameCapacity else {
            return nil
        }
        invalidateRuntime("Audio stopped because the device changed its callback size beyond the allocated safety margin. Restart the engine.")
        recordDroppedFrames(UInt32(frameCount))
        return noErr
    }

    func averageMicros(totals: [UInt64], count: Int) -> UInt64 {
        guard count > 0 else { return 0 }
        return totals.reduce(0, +) / UInt64(count)
    }

    private func latencyTelemetrySnapshot(
        tracks: [TrackRuntime],
        shards: [BufferedTrackWorkerShard]
    ) -> LatencyClassTelemetrySnapshot {
        LatencyClassTelemetrySnapshot(
            trackCount: tracks.count,
            workerShardCount: shards.count,
            peakTrackRenderDurationMicros: tracks.reduce(UInt64(0)) { partialResult, runtime in
                max(partialResult, runtime.peakRenderDurationMicros())
            },
            averageTrackRenderDurationMicros: averageMicros(
                totals: tracks.map { $0.averageRenderDurationMicros() },
                count: tracks.count
            ),
            peakShardRenderDurationMicros: shards.reduce(UInt64(0)) { partialResult, shard in
                max(partialResult, shard.peakRenderDurationMicros())
            },
            averageShardRenderDurationMicros: averageMicros(
                totals: shards.map { $0.averageRenderDurationMicros() },
                count: shards.count
            ),
            peakShardUtilizationPercent: shards.reduce(0) { max($0, $1.peakUtilization()) },
            peakWorkerWakeupsPerSecond: shards.reduce(0) { max($0, $1.peakWakeups()) }
        )
    }

    @MainActor
    func closePluginEditorWindowsOnMainActor() {
        for (editorKey, windowController) in pluginEditorWindows {
            if let session = pluginEditorSessions[editorKey] {
                session.invalidate()
            }
            windowController.close()
        }
        pluginEditorSessions.removeAll()
        pluginEditorWindows.removeAll()
    }
}
