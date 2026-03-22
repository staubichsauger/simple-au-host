import AudioToolbox
import CoreAudio
import Foundation

typealias AudioDeviceID = AudioObjectID

struct AudioDeviceInfo: Identifiable, Hashable {
    let id: AudioDeviceID
    let name: String
    let inputChannelCount: Int
    let outputChannelCount: Int
    let nominalSampleRate: Double
    let currentBufferSize: Int
    let bufferSizeRange: ClosedRange<Int>

    var displayName: String {
        "\(name) — \(Int(nominalSampleRate)) Hz"
    }
}

struct AudioUnitPluginInfo: Identifiable, Hashable {
    let id: String
    let name: String
    let componentDescription: AudioComponentDescription

    static func == (lhs: AudioUnitPluginInfo, rhs: AudioUnitPluginInfo) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

struct AudioHostConfiguration {
    let inputDevice: AudioDeviceInfo
    let outputDevice: AudioDeviceInfo
    let bufferSize: Int
    let inputChannel: Int
    let outputChannel: Int
    let plugin: AudioUnitPluginInfo?
    let threadedProcessingEnabled: Bool
    let threadedProcessingBufferSize: Int
}

struct AudioHostError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? {
        message
    }
}

struct AudioEngineTelemetrySnapshot {
    let peakInputCallbackFrames: UInt64
    let peakOutputCallbackFrames: UInt64
    let peakEffectRenderFrames: UInt64
    let peakInputRingOccupancyFrames: UInt64
    let peakOutputRingOccupancyFrames: UInt64
    let inputRingCapacityFrames: Int
    let outputRingCapacityFrames: Int
    let peakTrackRenderDurationMicros: UInt64
    let averageTrackRenderDurationMicros: UInt64
    let peakShardRenderDurationMicros: UInt64
    let averageShardRenderDurationMicros: UInt64
    let peakShardUtilizationPercent: UInt64
    let peakWorkerWakeupsPerSecond: UInt64
    let workerShardCount: Int

    static let zero = AudioEngineTelemetrySnapshot(
        peakInputCallbackFrames: 0,
        peakOutputCallbackFrames: 0,
        peakEffectRenderFrames: 0,
        peakInputRingOccupancyFrames: 0,
        peakOutputRingOccupancyFrames: 0,
        inputRingCapacityFrames: 0,
        outputRingCapacityFrames: 0,
        peakTrackRenderDurationMicros: 0,
        averageTrackRenderDurationMicros: 0,
        peakShardRenderDurationMicros: 0,
        averageShardRenderDurationMicros: 0,
        peakShardUtilizationPercent: 0,
        peakWorkerWakeupsPerSecond: 0,
        workerShardCount: 0
    )
}

final class AudioHostController: @unchecked Sendable {
    private static let pluginCatalogLock = NSLock()
    private nonisolated(unsafe) static var cachedPlugins: [AudioUnitPluginInfo]?

    private var inputUnit: AudioUnit?
    private var outputUnit: AudioUnit?
    private var effectUnit: AudioUnit?

    private var currentConfiguration: AudioHostConfiguration?
    private var effectChannelCount: UInt32 = 1
    private var ioMaxFramesPerSlice: UInt32 = 0
    private var effectMaxFramesPerSlice: UInt32 = 0
    private var callbackFrameCapacity: Int = 0

    private var captureBuffer: UnsafeMutablePointer<Float>?
    private var dryScratchBuffer: UnsafeMutablePointer<Float>?
    private var wetBuffer1: UnsafeMutablePointer<Float>?
    private var wetBuffer2: UnsafeMutablePointer<Float>?
    private var threadedInputScratchBuffer: UnsafeMutablePointer<Float>?
    private var threadedOutputScratchBuffer: UnsafeMutablePointer<Float>?

    private var captureBufferList: UnsafeMutableAudioBufferListPointer?
    private var wetBufferList: UnsafeMutableAudioBufferListPointer?

    private var drySourceForEffect: UnsafeMutablePointer<Float>?
    private var dryRingBuffer = SAHFloatRingBuffer()
    private var threadedOutputRingBuffer = SAHFloatRingBuffer()
    private var audioDropoutCounter = SAHAtomicCounter()
    private var droppedFrameCounter = SAHAtomicCounter()
    private var peakInputCallbackFrames = SAHAtomicCounter()
    private var peakOutputCallbackFrames = SAHAtomicCounter()
    private var peakEffectRenderFrames = SAHAtomicCounter()
    private var peakInputRingOccupancyFrames = SAHAtomicCounter()
    private var peakOutputRingOccupancyFrames = SAHAtomicCounter()
    private var nextExpectedInputSampleTime: Double?
    private var nextExpectedOutputSampleTime: Double?
    private var effectRenderSampleTime: Double = 0
    private let priorityController = AudioHostingPriorityController()
    private let workerStateLock = NSLock()
    private let runtimeStateLock = NSLock()
    private let workerWakeup = AudioWorkerWakeup()
    private let workerExitGroup = DispatchGroup()
    private let deviceObserver = AudioHardwareChangeObserver()
    private var workerThread: Thread?
    private var shouldRunWorker = false
    private var threadedOutputPrimed = false
    private var runtimeStatus: String?
    private var inputRingCapacityFrames = 0
    private var outputRingCapacityFrames = 0

    private var isRunning = false

    deinit {
        stop()
    }

    func availableDevices() throws -> [AudioDeviceInfo] {
        let devices: [AudioDeviceID] = try getAudioObjectProperty(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyDevices,
            scope: kAudioObjectPropertyScopeGlobal,
            element: kAudioObjectPropertyElementMain
        )

        return try devices.compactMap { deviceID in
            let name = try getCFStringProperty(
                objectID: deviceID,
                selector: kAudioObjectPropertyName,
                scope: kAudioObjectPropertyScopeGlobal,
                element: kAudioObjectPropertyElementMain
            )
            let inputChannels = try channelCount(deviceID: deviceID, scope: kAudioObjectPropertyScopeInput)
            let outputChannels = try channelCount(deviceID: deviceID, scope: kAudioObjectPropertyScopeOutput)
            let sampleRate: Float64 = try getAudioObjectScalarProperty(
                objectID: deviceID,
                selector: kAudioDevicePropertyNominalSampleRate,
                scope: kAudioObjectPropertyScopeGlobal,
                element: kAudioObjectPropertyElementMain
            )
            let currentBufferSize: UInt32 = try getAudioObjectScalarProperty(
                objectID: deviceID,
                selector: kAudioDevicePropertyBufferFrameSize,
                scope: kAudioObjectPropertyScopeGlobal,
                element: kAudioObjectPropertyElementMain
            )
            let range: AudioValueRange = try getAudioObjectScalarProperty(
                objectID: deviceID,
                selector: kAudioDevicePropertyBufferFrameSizeRange,
                scope: kAudioObjectPropertyScopeGlobal,
                element: kAudioObjectPropertyElementMain
            )

            return AudioDeviceInfo(
                id: deviceID,
                name: name,
                inputChannelCount: inputChannels,
                outputChannelCount: outputChannels,
                nominalSampleRate: sampleRate,
                currentBufferSize: Int(currentBufferSize),
                bufferSizeRange: Int(range.mMinimum)...Int(range.mMaximum)
            )
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func availablePlugins() throws -> [AudioUnitPluginInfo] {
        Self.pluginCatalogLock.lock()
        if let cachedPlugins = Self.cachedPlugins {
            Self.pluginCatalogLock.unlock()
            return cachedPlugins
        }
        Self.pluginCatalogLock.unlock()

        var plugins: [AudioUnitPluginInfo] = []
        var seenIDs = Set<String>()

        for componentType in [kAudioUnitType_Effect, kAudioUnitType_MusicEffect] {
            var searchDescription = AudioComponentDescription(
                componentType: componentType,
                componentSubType: 0,
                componentManufacturer: 0,
                componentFlags: 0,
                componentFlagsMask: 0
            )

            var currentComponent: AudioComponent?
            while true {
                let nextComponent = AudioComponentFindNext(currentComponent, &searchDescription)
                guard let component = nextComponent else { break }

                var description = AudioComponentDescription()
                try checkStatus(
                    AudioComponentGetDescription(component, &description),
                    "Failed to read Audio Unit description"
                )

                var nameRef: Unmanaged<CFString>?
                try checkStatus(
                    AudioComponentCopyName(component, &nameRef),
                    "Failed to read Audio Unit name"
                )
                let rawName = nameRef?.takeRetainedValue() as String? ?? "Unknown Audio Unit"
                let pluginID = [
                    String(description.componentType),
                    String(description.componentSubType),
                    String(description.componentManufacturer)
                ].joined(separator: ":")

                if seenIDs.insert(pluginID).inserted {
                    plugins.append(
                        AudioUnitPluginInfo(
                            id: pluginID,
                            name: rawName,
                            componentDescription: description
                        )
                    )
                }

                currentComponent = component
            }
        }

        let sortedPlugins = plugins.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        Self.pluginCatalogLock.lock()
        Self.cachedPlugins = sortedPlugins
        Self.pluginCatalogLock.unlock()
        return sortedPlugins
    }

    func defaultInputDeviceID() throws -> AudioDeviceID {
        try getAudioObjectScalarProperty(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyDefaultInputDevice,
            scope: kAudioObjectPropertyScopeGlobal,
            element: kAudioObjectPropertyElementMain
        )
    }

    func defaultOutputDeviceID() throws -> AudioDeviceID {
        try getAudioObjectScalarProperty(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyDefaultOutputDevice,
            scope: kAudioObjectPropertyScopeGlobal,
            element: kAudioObjectPropertyElementMain
        )
    }

    func start(configuration: AudioHostConfiguration) throws {
        stop()
        SAHAtomicCounterReset(&audioDropoutCounter)
        SAHAtomicCounterReset(&droppedFrameCounter)
        resetTelemetry()
        nextExpectedInputSampleTime = nil
        nextExpectedOutputSampleTime = nil
        effectRenderSampleTime = 0
        threadedOutputPrimed = false
        clearRuntimeStatus()
        priorityController.activate(reason: "Low-latency audio hosting")

        do {
            guard configuration.inputDevice.inputChannelCount >= configuration.inputChannel else {
                throw AudioHostError("The selected input channel does not exist on the chosen input interface.")
            }
            guard configuration.outputDevice.outputChannelCount >= configuration.outputChannel else {
                throw AudioHostError("The selected output channel does not exist on the chosen output interface.")
            }

            let sampleRateDifference = abs(configuration.inputDevice.nominalSampleRate - configuration.outputDevice.nominalSampleRate)
            guard sampleRateDifference < 0.5 else {
                throw AudioHostError("Input and output sample rates must already match for v1.")
            }

            try applyBufferSize(configuration.bufferSize, to: configuration.inputDevice.id)
            if configuration.outputDevice.id != configuration.inputDevice.id {
                try applyBufferSize(configuration.bufferSize, to: configuration.outputDevice.id)
            }

            currentConfiguration = configuration
            let threadedMaxFrames = configuration.threadedProcessingEnabled && configuration.plugin != nil
                ? max(configuration.bufferSize, configuration.threadedProcessingBufferSize)
                : configuration.bufferSize
            ioMaxFramesPerSlice = UInt32(suggestedMaximumFramesPerSlice(for: threadedMaxFrames, nominalBufferSize: configuration.bufferSize))
            effectMaxFramesPerSlice = UInt32(threadedMaxFrames)

            try createAndConfigureIOUnits(for: configuration)
            if let plugin = configuration.plugin {
                try createAndConfigureEffectUnit(plugin: plugin, sampleRate: configuration.inputDevice.nominalSampleRate)
            }
            let actualInputMaxFrames = try actualMaximumFramesPerSlice(for: inputUnit)
            let actualOutputMaxFrames = try actualMaximumFramesPerSlice(for: outputUnit)
            let actualEffectMaxFrames = try actualMaximumFramesPerSlice(for: effectUnit)
            callbackFrameCapacity = allocatedFrameCapacity(
                actualMaximumFrames: max(actualInputMaxFrames, max(actualOutputMaxFrames, actualEffectMaxFrames)),
                nominalBufferSize: configuration.bufferSize
            )
            try prepareBuffers(maxFrames: callbackFrameCapacity)
            installDeviceObservers(for: configuration)
            if shouldUseThreadedProcessing {
                startWorkerThread()
            }

            if let outputUnit {
                try checkStatus(AudioOutputUnitStart(outputUnit), "Failed to start output audio")
            }
            if let inputUnit {
                try checkStatus(AudioOutputUnitStart(inputUnit), "Failed to start input audio")
            }

            isRunning = true
        } catch {
            stop()
            throw error
        }
    }

    func audioDropoutCount() -> UInt64 {
        SAHAtomicCounterLoad(&audioDropoutCounter)
    }

    func droppedFrameCount() -> UInt64 {
        SAHAtomicCounterLoad(&droppedFrameCounter)
    }

    func resetDropoutCounters() {
        SAHAtomicCounterReset(&audioDropoutCounter)
        SAHAtomicCounterReset(&droppedFrameCounter)
        resetTelemetry()
        nextExpectedInputSampleTime = nil
        nextExpectedOutputSampleTime = nil
    }

    func runtimeStatusMessage() -> String? {
        runtimeStateLock.lock()
        defer { runtimeStateLock.unlock() }
        return runtimeStatus
    }

    func telemetrySnapshot() -> AudioEngineTelemetrySnapshot {
        AudioEngineTelemetrySnapshot(
            peakInputCallbackFrames: SAHAtomicCounterLoad(&peakInputCallbackFrames),
            peakOutputCallbackFrames: SAHAtomicCounterLoad(&peakOutputCallbackFrames),
            peakEffectRenderFrames: SAHAtomicCounterLoad(&peakEffectRenderFrames),
            peakInputRingOccupancyFrames: SAHAtomicCounterLoad(&peakInputRingOccupancyFrames),
            peakOutputRingOccupancyFrames: SAHAtomicCounterLoad(&peakOutputRingOccupancyFrames),
            inputRingCapacityFrames: inputRingCapacityFrames,
            outputRingCapacityFrames: outputRingCapacityFrames,
            peakTrackRenderDurationMicros: 0,
            averageTrackRenderDurationMicros: 0,
            peakShardRenderDurationMicros: 0,
            averageShardRenderDurationMicros: 0,
            peakShardUtilizationPercent: 0,
            peakWorkerWakeupsPerSecond: 0,
            workerShardCount: 0
        )
    }

    private func recordDroppedFrames(_ frameCount: UInt32) {
        guard frameCount > 0 else { return }
        SAHAtomicCounterIncrement(&audioDropoutCounter)
        SAHAtomicCounterAdd(&droppedFrameCounter, UInt64(frameCount))
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

    func stop() {
        stopWorkerThread()
        deviceObserver.stop()
        if let inputUnit {
            AudioOutputUnitStop(inputUnit)
        }
        if let outputUnit {
            AudioOutputUnitStop(outputUnit)
        }

        if let effectUnit {
            AudioUnitUninitialize(effectUnit)
            AudioComponentInstanceDispose(effectUnit)
        }
        if let inputUnit {
            AudioUnitUninitialize(inputUnit)
            AudioComponentInstanceDispose(inputUnit)
        }
        if let outputUnit {
            AudioUnitUninitialize(outputUnit)
            AudioComponentInstanceDispose(outputUnit)
        }

        effectUnit = nil
        inputUnit = nil
        outputUnit = nil

        teardownBuffers()
        SAHFloatRingBufferDeinit(&dryRingBuffer)

        currentConfiguration = nil
        effectChannelCount = 1
        ioMaxFramesPerSlice = 0
        effectMaxFramesPerSlice = 0
        callbackFrameCapacity = 0
        inputRingCapacityFrames = 0
        outputRingCapacityFrames = 0
        nextExpectedInputSampleTime = nil
        nextExpectedOutputSampleTime = nil
        effectRenderSampleTime = 0
        threadedOutputPrimed = false
        clearRuntimeStatus()
        isRunning = false
        priorityController.deactivate()
    }

    private func createAndConfigureIOUnits(for configuration: AudioHostConfiguration) throws {
        inputUnit = try createHALOutputUnit()
        outputUnit = try createHALOutputUnit()

        guard let inputUnit, let outputUnit else {
            throw AudioHostError("Failed to create Core Audio I/O units.")
        }

        var enableIO: UInt32 = 1
        var disableIO: UInt32 = 0
        var currentInputDevice = configuration.inputDevice.id
        var currentOutputDevice = configuration.outputDevice.id
        var monoFormat = streamFormat(channels: 1, sampleRate: configuration.inputDevice.nominalSampleRate)

        try checkStatus(
            AudioUnitSetProperty(
                inputUnit,
                kAudioOutputUnitProperty_EnableIO,
                kAudioUnitScope_Input,
                1,
                &enableIO,
                UInt32(MemoryLayout<UInt32>.size)
            ),
            "Failed to enable input on AUHAL"
        )
        try checkStatus(
            AudioUnitSetProperty(
                inputUnit,
                kAudioOutputUnitProperty_EnableIO,
                kAudioUnitScope_Output,
                0,
                &disableIO,
                UInt32(MemoryLayout<UInt32>.size)
            ),
            "Failed to disable output on input AUHAL"
        )
        try checkStatus(
            AudioUnitSetProperty(
                inputUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &currentInputDevice,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            ),
            "Failed to select input device"
        )

        var inputCallback = AURenderCallbackStruct(
            inputProc: Self.inputDeviceCallback,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
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
            "Failed to install input callback"
        )
        try checkStatus(
            AudioUnitSetProperty(
                inputUnit,
                kAudioUnitProperty_StreamFormat,
                kAudioUnitScope_Output,
                1,
                &monoFormat,
                UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            ),
            "Failed to set input stream format"
        )

        var inputChannelMap = [Int32(configuration.inputChannel - 1)]
        let inputChannelMapSize = UInt32(MemoryLayout<Int32>.size * inputChannelMap.count)
        _ = try inputChannelMap.withUnsafeMutableBufferPointer { mapBuffer in
            try checkStatus(
                AudioUnitSetProperty(
                    inputUnit,
                    kAudioOutputUnitProperty_ChannelMap,
                    kAudioUnitScope_Output,
                    1,
                    mapBuffer.baseAddress!,
                    inputChannelMapSize
                ),
                "Failed to set input channel map"
            )
        }

        var maxFrames = ioMaxFramesPerSlice
        try checkStatus(
            AudioUnitSetProperty(
                inputUnit,
                kAudioUnitProperty_MaximumFramesPerSlice,
                kAudioUnitScope_Global,
                0,
                &maxFrames,
                UInt32(MemoryLayout<UInt32>.size)
            ),
            "Failed to set input maximum frames per slice"
        )
        try checkStatus(AudioUnitInitialize(inputUnit), "Failed to initialize input AUHAL")

        try checkStatus(
            AudioUnitSetProperty(
                outputUnit,
                kAudioOutputUnitProperty_EnableIO,
                kAudioUnitScope_Output,
                0,
                &enableIO,
                UInt32(MemoryLayout<UInt32>.size)
            ),
            "Failed to enable output on AUHAL"
        )
        try checkStatus(
            AudioUnitSetProperty(
                outputUnit,
                kAudioOutputUnitProperty_EnableIO,
                kAudioUnitScope_Input,
                1,
                &disableIO,
                UInt32(MemoryLayout<UInt32>.size)
            ),
            "Failed to disable input on output AUHAL"
        )
        try checkStatus(
            AudioUnitSetProperty(
                outputUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &currentOutputDevice,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            ),
            "Failed to select output device"
        )

        var renderCallback = AURenderCallbackStruct(
            inputProc: Self.outputDeviceCallback,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        try checkStatus(
            AudioUnitSetProperty(
                outputUnit,
                kAudioUnitProperty_SetRenderCallback,
                kAudioUnitScope_Input,
                0,
                &renderCallback,
                UInt32(MemoryLayout<AURenderCallbackStruct>.size)
            ),
            "Failed to install output callback"
        )
        try checkStatus(
            AudioUnitSetProperty(
                outputUnit,
                kAudioUnitProperty_StreamFormat,
                kAudioUnitScope_Input,
                0,
                &monoFormat,
                UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            ),
            "Failed to set output stream format"
        )

        var outputChannelMap = Array(repeating: Int32(-1), count: configuration.outputDevice.outputChannelCount)
        outputChannelMap[configuration.outputChannel - 1] = 0
        let outputChannelMapSize = UInt32(MemoryLayout<Int32>.size * outputChannelMap.count)
        _ = try outputChannelMap.withUnsafeMutableBufferPointer { mapBuffer in
            try checkStatus(
                AudioUnitSetProperty(
                    outputUnit,
                    kAudioOutputUnitProperty_ChannelMap,
                    kAudioUnitScope_Output,
                    0,
                    mapBuffer.baseAddress!,
                    outputChannelMapSize
                ),
                "Failed to set output channel map"
            )
        }
        try checkStatus(
            AudioUnitSetProperty(
                outputUnit,
                kAudioUnitProperty_MaximumFramesPerSlice,
                kAudioUnitScope_Global,
                0,
                &maxFrames,
                UInt32(MemoryLayout<UInt32>.size)
            ),
            "Failed to set output maximum frames per slice"
        )
        try checkStatus(AudioUnitInitialize(outputUnit), "Failed to initialize output AUHAL")
    }

    private func createAndConfigureEffectUnit(plugin: AudioUnitPluginInfo, sampleRate: Double) throws {
        var componentDescription = plugin.componentDescription
        guard let component = AudioComponentFindNext(nil, &componentDescription) else {
            throw AudioHostError("The selected Audio Unit could not be found anymore.")
        }

        var createdUnit: AudioComponentInstance?
        try checkStatus(AudioComponentInstanceNew(component, &createdUnit), "Failed to instantiate Audio Unit")

        guard let createdUnit else {
            throw AudioHostError("Audio Unit instantiation returned no instance.")
        }

        effectUnit = createdUnit
        effectChannelCount = try preferredEffectChannelCount(for: createdUnit)

        var effectFormat = streamFormat(channels: effectChannelCount, sampleRate: sampleRate)
        var maxFrames = effectMaxFramesPerSlice

        var effectInputCallback = AURenderCallbackStruct(
            inputProc: Self.effectInputCallback,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        try checkStatus(
            AudioUnitSetProperty(
                createdUnit,
                kAudioUnitProperty_SetRenderCallback,
                kAudioUnitScope_Input,
                0,
                &effectInputCallback,
                UInt32(MemoryLayout<AURenderCallbackStruct>.size)
            ),
            "Failed to install Audio Unit input callback"
        )
        try checkStatus(
            AudioUnitSetProperty(
                createdUnit,
                kAudioUnitProperty_StreamFormat,
                kAudioUnitScope_Input,
                0,
                &effectFormat,
                UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            ),
            "Failed to set Audio Unit input format"
        )
        try checkStatus(
            AudioUnitSetProperty(
                createdUnit,
                kAudioUnitProperty_StreamFormat,
                kAudioUnitScope_Output,
                0,
                &effectFormat,
                UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            ),
            "Failed to set Audio Unit output format"
        )
        try checkStatus(
            AudioUnitSetProperty(
                createdUnit,
                kAudioUnitProperty_MaximumFramesPerSlice,
                kAudioUnitScope_Global,
                0,
                &maxFrames,
                UInt32(MemoryLayout<UInt32>.size)
            ),
            "Failed to set Audio Unit maximum frames per slice"
        )
        try checkStatus(AudioUnitInitialize(createdUnit), "Failed to initialize Audio Unit")

        try prepareBuffers(maxFrames: Int(effectMaxFramesPerSlice))
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

    private func preferredEffectChannelCount(for unit: AudioUnit) throws -> UInt32 {
        var size: UInt32 = 0
        var writable: DarwinBoolean = false
        let infoStatus = AudioUnitGetPropertyInfo(
            unit,
            kAudioUnitProperty_SupportedNumChannels,
            kAudioUnitScope_Global,
            0,
            &size,
            &writable
        )

        if infoStatus != noErr || size == 0 {
            return 1
        }

        let channelInfoCount = Int(size) / MemoryLayout<AUChannelInfo>.stride
        var channelInfos = Array(repeating: AUChannelInfo(inChannels: 0, outChannels: 0), count: channelInfoCount)
        try channelInfos.withUnsafeMutableBytes { bytes in
            guard let baseAddress = bytes.baseAddress else {
                throw AudioHostError("Failed to query Audio Unit channel support.")
            }
            try checkStatus(
                AudioUnitGetProperty(
                    unit,
                    kAudioUnitProperty_SupportedNumChannels,
                    kAudioUnitScope_Global,
                    0,
                    baseAddress,
                    &size
                ),
                "Failed to query Audio Unit channel support"
            )
        }

        if supports(channelCount: 1, in: channelInfos) {
            return 1
        }
        if supports(channelCount: 2, in: channelInfos) {
            return 2
        }
        return 1
    }

    private func supports(channelCount: Int, in infos: [AUChannelInfo]) -> Bool {
        for info in infos {
            let input = Int(info.inChannels)
            let output = Int(info.outChannels)

            if input == channelCount && output == channelCount {
                return true
            }
            if input == -1 && output == -1 {
                return true
            }
            if input == -1 && output == -2 {
                return true
            }
            if input == channelCount && output == -1 {
                return true
            }
            if input == -1 && output == channelCount {
                return true
            }
        }

        return false
    }

    private func prepareBuffers(maxFrames: Int) throws {
        teardownBuffers()

        let desiredCapacity = UInt32(max(maxFrames * 32, 2048))
        guard SAHFloatRingBufferInit(&dryRingBuffer, desiredCapacity) else {
            throw AudioHostError("Failed to allocate the realtime bridge buffer.")
        }
        inputRingCapacityFrames = Int(dryRingBuffer.capacity)
        if shouldUseThreadedProcessing {
            guard SAHFloatRingBufferInit(&threadedOutputRingBuffer, desiredCapacity) else {
                throw AudioHostError("Failed to allocate the threaded output buffer.")
            }
            outputRingCapacityFrames = Int(threadedOutputRingBuffer.capacity)
        } else {
            outputRingCapacityFrames = 0
        }

        captureBuffer = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames)
        dryScratchBuffer = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames)
        wetBuffer1 = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames)
        wetBuffer2 = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames)
        if shouldUseThreadedProcessing {
            threadedInputScratchBuffer = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames)
            threadedOutputScratchBuffer = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames)
        }

        captureBufferList = AudioBufferList.allocate(maximumBuffers: 1)
        captureBufferList?.count = 1
        captureBufferList?[0].mNumberChannels = 1
        captureBufferList?[0].mDataByteSize = UInt32(maxFrames * MemoryLayout<Float>.size)
        captureBufferList?[0].mData = UnsafeMutableRawPointer(captureBuffer)

        let wetBufferCount = max(Int(effectChannelCount), 1)
        wetBufferList = AudioBufferList.allocate(maximumBuffers: wetBufferCount)
        wetBufferList?.count = wetBufferCount

        if let wetBufferList {
            wetBufferList[0].mNumberChannels = 1
            wetBufferList[0].mDataByteSize = UInt32(maxFrames * MemoryLayout<Float>.size)
            wetBufferList[0].mData = UnsafeMutableRawPointer(wetBuffer1)

            if wetBufferCount > 1 {
                wetBufferList[1].mNumberChannels = 1
                wetBufferList[1].mDataByteSize = UInt32(maxFrames * MemoryLayout<Float>.size)
                wetBufferList[1].mData = UnsafeMutableRawPointer(wetBuffer2)
            }
        }
    }

    private func teardownBuffers() {
        captureBuffer?.deallocate()
        dryScratchBuffer?.deallocate()
        wetBuffer1?.deallocate()
        wetBuffer2?.deallocate()
        threadedInputScratchBuffer?.deallocate()
        threadedOutputScratchBuffer?.deallocate()

        captureBuffer = nil
        dryScratchBuffer = nil
        wetBuffer1 = nil
        wetBuffer2 = nil
        threadedInputScratchBuffer = nil
        threadedOutputScratchBuffer = nil

        captureBufferList?.unsafeMutablePointer.deallocate()
        wetBufferList?.unsafeMutablePointer.deallocate()
        captureBufferList = nil
        wetBufferList = nil

        drySourceForEffect = nil
        SAHFloatRingBufferDeinit(&threadedOutputRingBuffer)
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
            "Failed to apply the requested buffer size"
        )
    }

    private func channelCount(deviceID: AudioDeviceID, scope: AudioObjectPropertyScope) throws -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        try checkStatus(
            AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize),
            "Failed to inspect device stream configuration"
        )

        let rawPointer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawPointer.deallocate() }

        try checkStatus(
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, rawPointer),
            "Failed to read device stream configuration"
        )

        let bufferList = UnsafeMutableAudioBufferListPointer(
            rawPointer.assumingMemoryBound(to: AudioBufferList.self)
        )

        return bufferList.reduce(into: 0) { partialResult, buffer in
            partialResult += Int(buffer.mNumberChannels)
        }
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

    private static let inputDeviceCallback: AURenderCallback = { inRefCon, ioActionFlags, inTimeStamp, _, inNumberFrames, _ in
        let controller = Unmanaged<AudioHostController>.fromOpaque(inRefCon).takeUnretainedValue()
        return controller.handleInputCallback(
            ioActionFlags: ioActionFlags,
            inTimeStamp: inTimeStamp,
            inNumberFrames: inNumberFrames
        )
    }

    private static let outputDeviceCallback: AURenderCallback = { inRefCon, ioActionFlags, inTimeStamp, _, inNumberFrames, ioData in
        let controller = Unmanaged<AudioHostController>.fromOpaque(inRefCon).takeUnretainedValue()
        return controller.handleOutputCallback(
            ioActionFlags: ioActionFlags,
            inTimeStamp: inTimeStamp,
            inNumberFrames: inNumberFrames,
            ioData: ioData
        )
    }

    private static let effectInputCallback: AURenderCallback = { inRefCon, _, _, _, inNumberFrames, ioData in
        let controller = Unmanaged<AudioHostController>.fromOpaque(inRefCon).takeUnretainedValue()
        return controller.handleEffectInputCallback(inNumberFrames: inNumberFrames, ioData: ioData)
    }

    private func handleInputCallback(
        ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>?,
        inTimeStamp: UnsafePointer<AudioTimeStamp>?,
        inNumberFrames: UInt32
    ) -> OSStatus {
        guard
            let inputUnit,
            let captureBufferList,
            let captureBuffer
        else {
            return noErr
        }
        if let status = statusForInvalidCallbackFrameCount(Int(inNumberFrames)) {
            return status
        }
        if runtimeStatusMessage() != nil {
            return noErr
        }
        SAHAtomicCounterStoreMax(&peakInputCallbackFrames, UInt64(inNumberFrames))

        updateExpectedSampleTime(
            with: inTimeStamp,
            frameCount: inNumberFrames,
            expectedSampleTime: &nextExpectedInputSampleTime
        )

        captureBufferList[0].mDataByteSize = inNumberFrames * UInt32(MemoryLayout<Float>.size)

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
        let writtenFrames = SAHFloatRingBufferWrite(&dryRingBuffer, captureBuffer, inNumberFrames)
        SAHAtomicCounterStoreMax(&peakInputRingOccupancyFrames, UInt64(SAHFloatRingBufferAvailableRead(&dryRingBuffer)))
        if writtenFrames < inNumberFrames {
            recordDroppedFrames(inNumberFrames - writtenFrames)
        }
        if shouldUseThreadedProcessing {
            workerWakeup.signal()
        }
        return noErr
    }

    private func handleOutputCallback(
        ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>?,
        inTimeStamp: UnsafePointer<AudioTimeStamp>?,
        inNumberFrames: UInt32,
        ioData: UnsafeMutablePointer<AudioBufferList>?
    ) -> OSStatus {
        guard
            let ioData,
            let dryScratchBuffer,
            let outputBuffer = ioData.pointee.mBuffers.mData?.assumingMemoryBound(to: Float.self)
        else {
            return noErr
        }
        let requestedFrames = Int(inNumberFrames)
        let bytes = requestedFrames * MemoryLayout<Float>.size
        clearAudioBuffer(outputBuffer, frameCount: requestedFrames)
        if let status = statusForInvalidCallbackFrameCount(requestedFrames) {
            ioData.pointee.mBuffers.mDataByteSize = UInt32(bytes)
            return status
        }
        if runtimeStatusMessage() != nil {
            ioData.pointee.mBuffers.mDataByteSize = UInt32(bytes)
            return noErr
        }
        SAHAtomicCounterStoreMax(&peakOutputCallbackFrames, UInt64(inNumberFrames))

        updateExpectedSampleTime(
            with: inTimeStamp,
            frameCount: inNumberFrames,
            expectedSampleTime: &nextExpectedOutputSampleTime
        )

        if shouldUseThreadedProcessing {
            let prerollFrames = max(effectMaxFramesPerSlice, inNumberFrames * 2)
            if !threadedOutputPrimed {
                if SAHFloatRingBufferAvailableRead(&threadedOutputRingBuffer) < prerollFrames {
                    ioData.pointee.mBuffers.mDataByteSize = UInt32(bytes)
                    _ = ioActionFlags
                    return noErr
                }
                threadedOutputPrimed = true
            }
            let readFrames = Int(SAHFloatRingBufferRead(&threadedOutputRingBuffer, outputBuffer, inNumberFrames))
            SAHAtomicCounterStoreMax(&peakOutputRingOccupancyFrames, UInt64(SAHFloatRingBufferAvailableRead(&threadedOutputRingBuffer)))
            workerWakeup.signal()
            if readFrames < requestedFrames {
                threadedOutputPrimed = false
                recordDroppedFrames(UInt32(requestedFrames - readFrames))
                for frame in readFrames..<requestedFrames {
                    outputBuffer[frame] = 0
                }
            }
            ioData.pointee.mBuffers.mDataByteSize = UInt32(bytes)
            _ = ioActionFlags
            return noErr
        }

        let readFrames = Int(SAHFloatRingBufferRead(&dryRingBuffer, dryScratchBuffer, inNumberFrames))
        SAHAtomicCounterStoreMax(&peakInputRingOccupancyFrames, UInt64(SAHFloatRingBufferAvailableRead(&dryRingBuffer)))
        if readFrames < requestedFrames {
            recordDroppedFrames(UInt32(requestedFrames - readFrames))
            for frame in readFrames..<requestedFrames {
                dryScratchBuffer[frame] = 0
            }
        }

        guard let effectUnit else {
            outputBuffer.update(from: dryScratchBuffer, count: requestedFrames)
            ioData.pointee.mBuffers.mDataByteSize = UInt32(bytes)
            return noErr
        }

        drySourceForEffect = dryScratchBuffer
        guard let wetBufferList else {
            outputBuffer.update(from: dryScratchBuffer, count: requestedFrames)
            ioData.pointee.mBuffers.mDataByteSize = UInt32(bytes)
            return noErr
        }

        for index in 0..<wetBufferList.count {
            wetBufferList[index].mDataByteSize = UInt32(bytes)
        }

        var renderFlags: AudioUnitRenderActionFlags = []
        var timeStamp = inTimeStamp?.pointee ?? AudioTimeStamp()
        let renderStatus = AudioUnitRender(
            effectUnit,
            &renderFlags,
            &timeStamp,
            0,
            inNumberFrames,
            wetBufferList.unsafeMutablePointer
        )
        drySourceForEffect = nil

        if renderStatus != noErr {
            recordDroppedFrames(inNumberFrames)
            outputBuffer.update(from: dryScratchBuffer, count: requestedFrames)
            ioData.pointee.mBuffers.mDataByteSize = UInt32(bytes)
            return noErr
        }

        guard
            let wetBuffer1
        else {
            outputBuffer.update(from: dryScratchBuffer, count: requestedFrames)
            ioData.pointee.mBuffers.mDataByteSize = UInt32(bytes)
            return noErr
        }

        if wetBufferList.count == 1 {
            outputBuffer.update(from: wetBuffer1, count: requestedFrames)
        } else if let wetBuffer2 {
            for frame in 0..<requestedFrames {
                outputBuffer[frame] = (wetBuffer1[frame] + wetBuffer2[frame]) * 0.5
            }
        } else {
            outputBuffer.update(from: wetBuffer1, count: requestedFrames)
        }

        ioData.pointee.mBuffers.mDataByteSize = UInt32(bytes)
        return noErr
    }

    private func handleEffectInputCallback(
        inNumberFrames: UInt32,
        ioData: UnsafeMutablePointer<AudioBufferList>?
    ) -> OSStatus {
        guard let ioData else { return noErr }

        let bufferList = UnsafeMutableAudioBufferListPointer(ioData)
        let frameCount = Int(inNumberFrames)

        for bufferIndex in 0..<bufferList.count {
            guard let destination = bufferList[bufferIndex].mData?.assumingMemoryBound(to: Float.self) else {
                continue
            }

            if let drySourceForEffect {
                destination.update(from: drySourceForEffect, count: frameCount)
            } else {
                clearAudioBuffer(destination, frameCount: frameCount)
            }
            bufferList[bufferIndex].mDataByteSize = UInt32(frameCount * MemoryLayout<Float>.size)
        }

        return noErr
    }

    private var shouldUseThreadedProcessing: Bool {
        guard let currentConfiguration else { return false }
        return currentConfiguration.threadedProcessingEnabled && currentConfiguration.plugin != nil
    }

    private func startWorkerThread() {
        workerStateLock.lock()
        shouldRunWorker = true
        workerStateLock.unlock()
        workerExitGroup.enter()

        let workerThread = Thread { [weak self] in
            defer {
                self?.workerExitGroup.leave()
            }
            self?.workerLoop()
        }
        workerThread.name = "SimpleAUHost.SimpleWorker"
        workerThread.qualityOfService = .userInitiated
        self.workerThread = workerThread
        workerThread.start()
    }

    private func stopWorkerThread() {
        workerStateLock.lock()
        shouldRunWorker = false
        workerStateLock.unlock()

        workerThread?.cancel()
        workerWakeup.signal()
        if workerThread != nil {
            workerExitGroup.wait()
        }
        workerThread = nil
    }

    private func workerLoop() {
        guard shouldUseThreadedProcessing else { return }
        promoteCurrentThreadToAudioWorkerQoS()

        while shouldWorkerContinue() && !Thread.current.isCancelled {
            if runtimeStatusMessage() != nil {
                return
            }
            let frames = UInt32(effectMaxFramesPerSlice)
            let hasInput = SAHFloatRingBufferAvailableRead(&dryRingBuffer) >= frames
            let hasOutputSpace = SAHFloatRingBufferAvailableWrite(&threadedOutputRingBuffer) >= frames

            guard hasInput, hasOutputSpace else {
                workerWakeup.wait()
                continue
            }

            guard
                let threadedInputScratchBuffer,
                let threadedOutputScratchBuffer
            else {
                return
            }

            let readFrames = SAHFloatRingBufferRead(&dryRingBuffer, threadedInputScratchBuffer, frames)
            SAHAtomicCounterStoreMax(&peakInputRingOccupancyFrames, UInt64(SAHFloatRingBufferAvailableRead(&dryRingBuffer)))
            if readFrames < frames {
                recordDroppedFrames(frames - readFrames)
                for frame in Int(readFrames)..<Int(frames) {
                    threadedInputScratchBuffer[frame] = 0
                }
            }

            renderThreadedEffect(
                frameCount: Int(frames),
                dryInput: threadedInputScratchBuffer,
                monoOutput: threadedOutputScratchBuffer
            )

            let writtenFrames = SAHFloatRingBufferWrite(&threadedOutputRingBuffer, threadedOutputScratchBuffer, frames)
            SAHAtomicCounterStoreMax(&peakOutputRingOccupancyFrames, UInt64(SAHFloatRingBufferAvailableRead(&threadedOutputRingBuffer)))
            if writtenFrames < frames {
                recordDroppedFrames(frames - writtenFrames)
            }
        }
    }

    private func shouldWorkerContinue() -> Bool {
        workerStateLock.lock()
        defer { workerStateLock.unlock() }
        return shouldRunWorker
    }

    private func renderThreadedEffect(
        frameCount: Int,
        dryInput: UnsafeMutablePointer<Float>,
        monoOutput: UnsafeMutablePointer<Float>
    ) {
        guard let effectUnit else {
            monoOutput.update(from: dryInput, count: frameCount)
            return
        }

        drySourceForEffect = dryInput
        guard let wetBufferList else {
            drySourceForEffect = nil
            monoOutput.update(from: dryInput, count: frameCount)
            return
        }

        let bytes = UInt32(frameCount * MemoryLayout<Float>.size)
        SAHAtomicCounterStoreMax(&peakEffectRenderFrames, UInt64(frameCount))
        for index in 0..<wetBufferList.count {
            wetBufferList[index].mDataByteSize = bytes
        }

        var renderFlags: AudioUnitRenderActionFlags = []
        var timeStamp = AudioTimeStamp()
        timeStamp.mSampleTime = effectRenderSampleTime
        timeStamp.mFlags = AudioTimeStampFlags(rawValue: 1 << 0)

        let renderStatus = AudioUnitRender(
            effectUnit,
            &renderFlags,
            &timeStamp,
            0,
            UInt32(frameCount),
            wetBufferList.unsafeMutablePointer
        )
        drySourceForEffect = nil
        effectRenderSampleTime += Double(frameCount)

        if renderStatus != noErr {
            recordDroppedFrames(UInt32(frameCount))
            monoOutput.update(from: dryInput, count: frameCount)
            return
        }

        guard let wetBuffer1 else {
            monoOutput.update(from: dryInput, count: frameCount)
            return
        }

        if wetBufferList.count == 1 {
            monoOutput.update(from: wetBuffer1, count: frameCount)
        } else if let wetBuffer2 {
            for frame in 0..<frameCount {
                monoOutput[frame] = (wetBuffer1[frame] + wetBuffer2[frame]) * 0.5
            }
        } else {
            monoOutput.update(from: wetBuffer1, count: frameCount)
        }
    }
}

private extension AudioHostController {
    func resetTelemetry() {
        SAHAtomicCounterReset(&peakInputCallbackFrames)
        SAHAtomicCounterReset(&peakOutputCallbackFrames)
        SAHAtomicCounterReset(&peakEffectRenderFrames)
        SAHAtomicCounterReset(&peakInputRingOccupancyFrames)
        SAHAtomicCounterReset(&peakOutputRingOccupancyFrames)
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
            "Failed to query Audio Unit maximum frames per slice"
        )
        return Int(frames)
    }

    func installDeviceObservers(for configuration: AudioHostConfiguration) {
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
        workerWakeup.signal()
    }

    func clearRuntimeStatus() {
        runtimeStateLock.lock()
        runtimeStatus = nil
        runtimeStateLock.unlock()
    }

    func statusForInvalidCallbackFrameCount(_ frameCount: Int) -> OSStatus? {
        guard frameCount > callbackFrameCapacity else {
            return nil
        }
        invalidateRuntime("Audio stopped because the device changed its callback size beyond the allocated safety margin. Restart the engine.")
        recordDroppedFrames(UInt32(frameCount))
        return noErr
    }
}

func getAudioObjectProperty<T>(
    objectID: AudioObjectID,
    selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope,
    element: AudioObjectPropertyElement
) throws -> [T] {
    var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: scope,
        mElement: element
    )

    var dataSize: UInt32 = 0
    try checkStatus(
        AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &dataSize),
        "Failed to inspect Core Audio property"
    )

    let count = Int(dataSize) / MemoryLayout<T>.stride
    if count == 0 {
        return []
    }
    var values = Array<T>(unsafeUninitializedCapacity: count) { buffer, initializedCount in
        initializedCount = count
    }

    try values.withUnsafeMutableBytes { bytes in
        guard let baseAddress = bytes.baseAddress else {
            throw AudioHostError("Failed to read Core Audio property.")
        }
        try checkStatus(
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &dataSize, baseAddress),
            "Failed to read Core Audio property"
        )
    }

    return values
}

func getAudioObjectScalarProperty<T>(
    objectID: AudioObjectID,
    selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope,
    element: AudioObjectPropertyElement
) throws -> T {
    var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: scope,
        mElement: element
    )
    let pointer = UnsafeMutablePointer<T>.allocate(capacity: 1)
    defer { pointer.deallocate() }

    var dataSize = UInt32(MemoryLayout<T>.size)
    try checkStatus(
        AudioObjectGetPropertyData(objectID, &address, 0, nil, &dataSize, pointer),
        "Failed to read Core Audio scalar property"
    )

    return pointer.move()
}

func getCFStringProperty(
    objectID: AudioObjectID,
    selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope,
    element: AudioObjectPropertyElement
) throws -> String {
    var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: scope,
        mElement: element
    )
    var value: CFString?
    var dataSize = UInt32(MemoryLayout<CFString?>.size)

    try checkStatus(
        withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &dataSize, pointer)
        },
        "Failed to read Core Audio string property"
    )

    return (value as String?) ?? "Unknown"
}

@discardableResult
func checkStatus(_ status: OSStatus, _ message: String) throws -> OSStatus {
    guard status == noErr else {
        throw AudioHostError("\(message) (\(describe(status: status))).")
    }
    return status
}

func describe(status: OSStatus) -> String {
    let n = UInt32(bitPattern: status)
    let chars = [
        Character(UnicodeScalar((n >> 24) & 0xFF)!),
        Character(UnicodeScalar((n >> 16) & 0xFF)!),
        Character(UnicodeScalar((n >> 8) & 0xFF)!),
        Character(UnicodeScalar(n & 0xFF)!)
    ]
    let fourCC = String(chars)
    if fourCC.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value <= 126 }) {
        return "'\(fourCC)'"
    }
    return String(status)
}

final class AudioHostingPriorityController {
    private var activityToken: NSObjectProtocol?

    func activate(reason: String) {
        guard activityToken == nil else { return }

        var options: ProcessInfo.ActivityOptions = [
            .userInitiatedAllowingIdleSystemSleep,
            .suddenTerminationDisabled,
            .automaticTerminationDisabled
        ]
        options.insert(.latencyCritical)
        activityToken = ProcessInfo.processInfo.beginActivity(options: options, reason: reason)
    }

    func deactivate() {
        guard let activityToken else { return }
        ProcessInfo.processInfo.endActivity(activityToken)
        self.activityToken = nil
    }
}

final class AudioWorkerWakeup {
    private var mutex = pthread_mutex_t()
    private var condition = pthread_cond_t()
    private var isSignaled = false

    init() {
        pthread_mutex_init(&mutex, nil)
        pthread_cond_init(&condition, nil)
    }

    deinit {
        pthread_cond_destroy(&condition)
        pthread_mutex_destroy(&mutex)
    }

    func signal() {
        pthread_mutex_lock(&mutex)
        isSignaled = true
        pthread_cond_signal(&condition)
        pthread_mutex_unlock(&mutex)
    }

    func wait() {
        pthread_mutex_lock(&mutex)
        while !isSignaled {
            pthread_cond_wait(&condition, &mutex)
        }
        isSignaled = false
        pthread_mutex_unlock(&mutex)
    }
}

final class AudioHardwareChangeObserver {
    private let queue = DispatchQueue(label: "SimpleAUHost.AudioHardwareChangeObserver")
    private var registrations: [(AudioDeviceID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    func startMonitoring(deviceIDs: [AudioDeviceID], onChange: @escaping (String) -> Void) {
        stop()

        let addresses = [
            AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyBufferFrameSize,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            ),
            AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyNominalSampleRate,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            ),
            AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceIsAlive,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
        ]

        for deviceID in Set(deviceIDs) {
            for address in addresses {
                var propertyAddress = address
                let block: AudioObjectPropertyListenerBlock = { _, _ in
                    onChange("Audio stopped because the device configuration changed. Restart the engine to re-open the devices.")
                }
                let status = AudioObjectAddPropertyListenerBlock(deviceID, &propertyAddress, queue, block)
                if status == noErr {
                    registrations.append((deviceID, address, block))
                }
            }
        }
    }

    func stop() {
        for (deviceID, address, block) in registrations {
            var propertyAddress = address
            AudioObjectRemovePropertyListenerBlock(deviceID, &propertyAddress, queue, block)
        }
        registrations.removeAll()
    }

    deinit {
        stop()
    }
}

func clearAudioBuffer(_ pointer: UnsafeMutablePointer<Float>, frameCount: Int) {
    guard frameCount > 0 else { return }
    memset(pointer, 0, frameCount * MemoryLayout<Float>.size)
}

func suggestedMaximumFramesPerSlice(for processingFrames: Int, nominalBufferSize: Int) -> Int {
    max(processingFrames, nominalBufferSize * 4)
}

func allocatedFrameCapacity(actualMaximumFrames: Int, nominalBufferSize: Int) -> Int {
    max(actualMaximumFrames, nominalBufferSize) + nominalBufferSize
}

func promoteCurrentThreadToAudioWorkerQoS() {
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INITIATED, 0)
}
