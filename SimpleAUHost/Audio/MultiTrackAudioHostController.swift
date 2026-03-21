import AudioToolbox
import CoreAudio
import Foundation

final class MultiTrackAudioHostController: @unchecked Sendable {
    private final class TrackRuntime: @unchecked Sendable {
        let configuration: MultiTrackTrackConfiguration
        let processingFrames: Int
        let sampleRate: Double

        private var effectUnit: AudioUnit?
        private var wetBufferList: UnsafeMutableAudioBufferListPointer?
        private var inputRing1 = SAHFloatRingBuffer()
        private var inputRing2 = SAHFloatRingBuffer()
        private var outputRing1 = SAHFloatRingBuffer()
        private var outputRing2 = SAHFloatRingBuffer()
        private var inputScratch1: UnsafeMutablePointer<Float>?
        private var inputScratch2: UnsafeMutablePointer<Float>?
        private var outputScratch1: UnsafeMutablePointer<Float>?
        private var outputScratch2: UnsafeMutablePointer<Float>?
        private var currentInputSource1: UnsafeMutablePointer<Float>?
        private var currentInputSource2: UnsafeMutablePointer<Float>?
        private var workerThread: Thread?
        private let workerStateLock = NSLock()
        private let workerWakeup = AudioWorkerWakeup()
        private let workerExitGroup = DispatchGroup()
        private var shouldRunWorker = false
        private var bufferedOutputPrimed = false
        private var renderSampleTime: Double = 0
        private var audioDropoutCounter = SAHAtomicCounter()
        private var droppedFrameCounter = SAHAtomicCounter()

        init(
            configuration: MultiTrackTrackConfiguration,
            plugin: AudioUnitPluginInfo?,
            sampleRate: Double,
            hardwareBufferSize: Int,
            internalBufferFrames: Int
        ) throws {
            self.configuration = configuration
            self.sampleRate = sampleRate
            self.processingFrames = configuration.latencyClass == .realtime
                ? hardwareBufferSize
                : max(hardwareBufferSize, internalBufferFrames)
            SAHAtomicCounterReset(&audioDropoutCounter)
            SAHAtomicCounterReset(&droppedFrameCounter)

            try prepareBuffers()

            if let plugin {
                effectUnit = try Self.createEffectUnit(
                    plugin: plugin,
                    sampleRate: sampleRate,
                    channelCount: configuration.channelCount,
                    maximumFrames: processingFrames,
                    owner: self
                )
            }

            if configuration.latencyClass != .realtime {
                startWorker()
            }
        }

        deinit {
            stopWorker()
            if let effectUnit {
                AudioUnitUninitialize(effectUnit)
                AudioComponentInstanceDispose(effectUnit)
            }
            wetBufferList?.unsafeMutablePointer.deallocate()
            inputScratch1?.deallocate()
            inputScratch2?.deallocate()
            outputScratch1?.deallocate()
            outputScratch2?.deallocate()
            SAHFloatRingBufferDeinit(&inputRing1)
            SAHFloatRingBufferDeinit(&inputRing2)
            SAHFloatRingBufferDeinit(&outputRing1)
            SAHFloatRingBufferDeinit(&outputRing2)
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
        }

        func enqueueInput(
            captureBuffers: UnsafeMutableAudioBufferListPointer,
            frameCount: UInt32
        ) {
            guard configuration.isEnabled else { return }

            let inputChannelOffset = configuration.inputStartChannel - 1
            var droppedFrames: UInt32 = 0
            if let source = captureBuffers[inputChannelOffset].mData?.assumingMemoryBound(to: Float.self) {
                let writtenFrames = SAHFloatRingBufferWrite(&inputRing1, source, frameCount)
                if writtenFrames < frameCount {
                    droppedFrames = max(droppedFrames, frameCount - writtenFrames)
                }
            } else {
                droppedFrames = max(droppedFrames, frameCount)
            }

            if configuration.channelCount == 2,
               let source = captureBuffers[inputChannelOffset + 1].mData?.assumingMemoryBound(to: Float.self) {
                let writtenFrames = SAHFloatRingBufferWrite(&inputRing2, source, frameCount)
                if writtenFrames < frameCount {
                    droppedFrames = max(droppedFrames, frameCount - writtenFrames)
                }
            } else if configuration.channelCount == 2 {
                droppedFrames = max(droppedFrames, frameCount)
            }

            if droppedFrames > 0 {
                recordDroppedFrames(droppedFrames)
            }

            if configuration.latencyClass != .realtime {
                workerWakeup.signal()
            }
        }

        func mixOutput(into outputBuffers: UnsafeMutableAudioBufferListPointer, hardwareFrames: Int) {
            guard configuration.isEnabled else { return }
            if configuration.latencyClass == .realtime {
                renderRealtime(frames: hardwareFrames)
            } else {
                drainBufferedOutput(frames: hardwareFrames)
            }

            let outputChannelOffset = configuration.outputStartChannel - 1
            if let destination = outputBuffers[outputChannelOffset].mData?.assumingMemoryBound(to: Float.self),
               let source = outputScratch1 {
                for frame in 0..<hardwareFrames {
                    destination[frame] += source[frame]
                }
            }

            if configuration.channelCount == 2,
               let destination = outputBuffers[outputChannelOffset + 1].mData?.assumingMemoryBound(to: Float.self),
               let source = outputScratch2 {
                for frame in 0..<hardwareFrames {
                    destination[frame] += source[frame]
                }
            }
        }

        private func prepareBuffers() throws {
            let ringCapacity = UInt32(max(processingFrames * 32, 4096))

            guard SAHFloatRingBufferInit(&inputRing1, ringCapacity) else {
                throw AudioHostError("Failed to allocate multi-track input buffer.")
            }
            guard SAHFloatRingBufferInit(&outputRing1, ringCapacity) else {
                throw AudioHostError("Failed to allocate multi-track output buffer.")
            }

            if configuration.channelCount == 2 {
                guard SAHFloatRingBufferInit(&inputRing2, ringCapacity) else {
                    throw AudioHostError("Failed to allocate stereo input buffer.")
                }
                guard SAHFloatRingBufferInit(&outputRing2, ringCapacity) else {
                    throw AudioHostError("Failed to allocate stereo output buffer.")
                }
            }

            inputScratch1 = UnsafeMutablePointer<Float>.allocate(capacity: processingFrames)
            outputScratch1 = UnsafeMutablePointer<Float>.allocate(capacity: processingFrames)

            if configuration.channelCount == 2 {
                inputScratch2 = UnsafeMutablePointer<Float>.allocate(capacity: processingFrames)
                outputScratch2 = UnsafeMutablePointer<Float>.allocate(capacity: processingFrames)
            }

            wetBufferList = AudioBufferList.allocate(maximumBuffers: configuration.channelCount)
            wetBufferList?.count = configuration.channelCount

            wetBufferList?[0].mNumberChannels = 1
            wetBufferList?[0].mDataByteSize = UInt32(processingFrames * MemoryLayout<Float>.size)
            wetBufferList?[0].mData = UnsafeMutableRawPointer(outputScratch1)

            if configuration.channelCount == 2 {
                wetBufferList?[1].mNumberChannels = 1
                wetBufferList?[1].mDataByteSize = UInt32(processingFrames * MemoryLayout<Float>.size)
                wetBufferList?[1].mData = UnsafeMutableRawPointer(outputScratch2)
            }
        }

        private func renderRealtime(frames: Int) {
            guard let inputScratch1, let outputScratch1 else { return }

            let requestedFrames = UInt32(frames)
            let receivedFrames1 = SAHFloatRingBufferRead(&inputRing1, inputScratch1, requestedFrames)
            var droppedFrames = requestedFrames - receivedFrames1
            if Int(receivedFrames1) < frames {
                for frame in Int(receivedFrames1)..<frames {
                    inputScratch1[frame] = 0
                }
            }

            if configuration.channelCount == 2, let inputScratch2 {
                let receivedFrames2 = SAHFloatRingBufferRead(&inputRing2, inputScratch2, requestedFrames)
                droppedFrames = max(droppedFrames, requestedFrames - receivedFrames2)
                if Int(receivedFrames2) < frames {
                    for frame in Int(receivedFrames2)..<frames {
                        inputScratch2[frame] = 0
                    }
                }
            }

            if droppedFrames > 0 {
                recordDroppedFrames(droppedFrames)
            }

            _ = render(
                frameCount: frames,
                input1: inputScratch1,
                input2: configuration.channelCount == 2 ? inputScratch2 : nil
            )

            if configuration.channelCount == 1 {
                outputScratch1.advanced(by: frames).initialize(repeating: 0, count: max(0, processingFrames - frames))
            }
        }

        private func drainBufferedOutput(frames: Int) {
            guard let outputScratch1 else { return }
            let prerollFrames = UInt32(max(processingFrames, frames * 2))
            let availableFrames1 = SAHFloatRingBufferAvailableRead(&outputRing1)
            let availableFrames2 = configuration.channelCount == 1
                ? availableFrames1
                : SAHFloatRingBufferAvailableRead(&outputRing2)

            if !bufferedOutputPrimed {
                guard availableFrames1 >= prerollFrames, availableFrames2 >= prerollFrames else {
                    fillBufferedOutputScratchWithSilence(frames: frames)
                    return
                }
                bufferedOutputPrimed = true
            }
            let requestedFrames = UInt32(frames)
            let receivedFrames1 = SAHFloatRingBufferRead(&outputRing1, outputScratch1, requestedFrames)
            var droppedFrames = requestedFrames - receivedFrames1
            if Int(receivedFrames1) < frames {
                for frame in Int(receivedFrames1)..<frames {
                    outputScratch1[frame] = 0
                }
            }

            if configuration.channelCount == 2, let outputScratch2 {
                let receivedFrames2 = SAHFloatRingBufferRead(&outputRing2, outputScratch2, requestedFrames)
                droppedFrames = max(droppedFrames, requestedFrames - receivedFrames2)
                if Int(receivedFrames2) < frames {
                    for frame in Int(receivedFrames2)..<frames {
                        outputScratch2[frame] = 0
                    }
                }
            }

            if droppedFrames > 0 {
                bufferedOutputPrimed = false
                recordDroppedFrames(droppedFrames)
            }

            workerWakeup.signal()
        }

        private func startWorker() {
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
            workerThread.name = "SimpleAUHost.TrackWorker.\(configuration.id.uuidString)"
            workerThread.qualityOfService = configuration.latencyClass == .broadcast ? .utility : .userInitiated
            self.workerThread = workerThread
            workerThread.start()
        }

        private func stopWorker() {
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
            guard configuration.latencyClass != .realtime else { return }

            while shouldWorkerContinue() && !Thread.current.isCancelled {
                let frames = UInt32(processingFrames)
                let hasInput1 = SAHFloatRingBufferAvailableRead(&inputRing1) >= frames
                let hasOutput1 = SAHFloatRingBufferAvailableWrite(&outputRing1) >= frames
                let hasInput2 = configuration.channelCount == 1 || SAHFloatRingBufferAvailableRead(&inputRing2) >= frames
                let hasOutput2 = configuration.channelCount == 1 || SAHFloatRingBufferAvailableWrite(&outputRing2) >= frames

                guard hasInput1, hasOutput1, hasInput2, hasOutput2 else {
                    workerWakeup.wait()
                    continue
                }

                guard let inputScratch1, let outputScratch1 else {
                    return
                }

                _ = SAHFloatRingBufferRead(&inputRing1, inputScratch1, frames)
                var inputScratch2Pointer: UnsafeMutablePointer<Float>?
                if configuration.channelCount == 2, let inputScratch2 {
                    _ = SAHFloatRingBufferRead(&inputRing2, inputScratch2, frames)
                    inputScratch2Pointer = inputScratch2
                }

                _ = render(
                    frameCount: processingFrames,
                    input1: inputScratch1,
                    input2: inputScratch2Pointer
                )
                let writtenFrames1 = SAHFloatRingBufferWrite(&outputRing1, outputScratch1, frames)
                var droppedFrames = frames - writtenFrames1
                if configuration.channelCount == 2, let outputScratch2 {
                    let writtenFrames2 = SAHFloatRingBufferWrite(&outputRing2, outputScratch2, frames)
                    droppedFrames = max(droppedFrames, frames - writtenFrames2)
                }

                if droppedFrames > 0 {
                    recordDroppedFrames(droppedFrames)
                }
            }
        }

        private func shouldWorkerContinue() -> Bool {
            workerStateLock.lock()
            defer { workerStateLock.unlock() }
            return shouldRunWorker
        }

        private func fillBufferedOutputScratchWithSilence(frames: Int) {
            guard let outputScratch1 else { return }
            for frame in 0..<frames {
                outputScratch1[frame] = 0
            }
            if configuration.channelCount == 2, let outputScratch2 {
                for frame in 0..<frames {
                    outputScratch2[frame] = 0
                }
            }
        }

        @discardableResult
        private func render(
            frameCount: Int,
            input1: UnsafeMutablePointer<Float>,
            input2: UnsafeMutablePointer<Float>?
        ) -> Bool {
            guard let outputScratch1 else { return false }

            if effectUnit == nil {
                outputScratch1.update(from: input1, count: frameCount)
                if configuration.channelCount == 2, let input2, let outputScratch2 {
                    outputScratch2.update(from: input2, count: frameCount)
                }
                renderSampleTime += Double(frameCount)
                return true
            }

            currentInputSource1 = input1
            currentInputSource2 = input2

            let bytes = UInt32(frameCount * MemoryLayout<Float>.size)
            if let wetBufferList {
                for index in 0..<wetBufferList.count {
                    wetBufferList[index].mDataByteSize = bytes
                }
            }

            var renderFlags: AudioUnitRenderActionFlags = []
            var timeStamp = AudioTimeStamp()
            timeStamp.mSampleTime = renderSampleTime
            timeStamp.mFlags = AudioTimeStampFlags(rawValue: 1 << 0)

            let status = AudioUnitRender(
                effectUnit!,
                &renderFlags,
                &timeStamp,
                0,
                UInt32(frameCount),
                wetBufferList!.unsafeMutablePointer
            )

            currentInputSource1 = nil
            currentInputSource2 = nil
            renderSampleTime += Double(frameCount)

            if status != noErr {
                recordDroppedFrames(UInt32(frameCount))
                outputScratch1.update(from: input1, count: frameCount)
                if configuration.channelCount == 2, let input2, let outputScratch2 {
                    outputScratch2.update(from: input2, count: frameCount)
                }
                return false
            }

            return true
        }

        private func recordDroppedFrames(_ frameCount: UInt32) {
            guard frameCount > 0 else { return }
            SAHAtomicCounterIncrement(&audioDropoutCounter)
            SAHAtomicCounterAdd(&droppedFrameCounter, UInt64(frameCount))
        }

        private func provideEffectInput(
            ioData: UnsafeMutablePointer<AudioBufferList>?,
            frameCount: UInt32
        ) -> OSStatus {
            guard let ioData else { return noErr }

            let bufferList = UnsafeMutableAudioBufferListPointer(ioData)
            let frames = Int(frameCount)

            if let currentInputSource1,
               let destination = bufferList[0].mData?.assumingMemoryBound(to: Float.self) {
                destination.update(from: currentInputSource1, count: frames)
                bufferList[0].mDataByteSize = UInt32(frames * MemoryLayout<Float>.size)
            }

            if configuration.channelCount == 2,
               let currentInputSource2,
               bufferList.count > 1,
               let destination = bufferList[1].mData?.assumingMemoryBound(to: Float.self) {
                destination.update(from: currentInputSource2, count: frames)
                bufferList[1].mDataByteSize = UInt32(frames * MemoryLayout<Float>.size)
            }

            return noErr
        }

        private static let effectInputCallback: AURenderCallback = { inRefCon, _, _, _, inNumberFrames, ioData in
            let runtime = Unmanaged<TrackRuntime>.fromOpaque(inRefCon).takeUnretainedValue()
            return runtime.provideEffectInput(ioData: ioData, frameCount: inNumberFrames)
        }

        private static func createEffectUnit(
            plugin: AudioUnitPluginInfo,
            sampleRate: Double,
            channelCount: Int,
            maximumFrames: Int,
            owner: TrackRuntime
        ) throws -> AudioUnit {
            var componentDescription = plugin.componentDescription
            guard let component = AudioComponentFindNext(nil, &componentDescription) else {
                throw AudioHostError("The selected Audio Unit could not be found anymore.")
            }

            var createdUnit: AudioComponentInstance?
            try checkStatus(AudioComponentInstanceNew(component, &createdUnit), "Failed to instantiate Audio Unit")

            guard let createdUnit else {
                throw AudioHostError("Audio Unit instantiation returned no instance.")
            }

            try ensurePlugin(createdUnit, supports: channelCount, pluginName: plugin.name)

            var streamFormat = AudioStreamBasicDescription(
                mSampleRate: sampleRate,
                mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved,
                mBytesPerPacket: UInt32(MemoryLayout<Float>.size),
                mFramesPerPacket: 1,
                mBytesPerFrame: UInt32(MemoryLayout<Float>.size),
                mChannelsPerFrame: UInt32(channelCount),
                mBitsPerChannel: 32,
                mReserved: 0
            )

            var maxFrames = UInt32(maximumFrames)
            var callback = AURenderCallbackStruct(
                inputProc: effectInputCallback,
                inputProcRefCon: Unmanaged.passUnretained(owner).toOpaque()
            )

            try checkStatus(
                AudioUnitSetProperty(
                    createdUnit,
                    kAudioUnitProperty_SetRenderCallback,
                    kAudioUnitScope_Input,
                    0,
                    &callback,
                    UInt32(MemoryLayout<AURenderCallbackStruct>.size)
                ),
                "Failed to install track Audio Unit input callback"
            )
            try checkStatus(
                AudioUnitSetProperty(
                    createdUnit,
                    kAudioUnitProperty_StreamFormat,
                    kAudioUnitScope_Input,
                    0,
                    &streamFormat,
                    UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
                ),
                "Failed to set track Audio Unit input format"
            )
            try checkStatus(
                AudioUnitSetProperty(
                    createdUnit,
                    kAudioUnitProperty_StreamFormat,
                    kAudioUnitScope_Output,
                    0,
                    &streamFormat,
                    UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
                ),
                "Failed to set track Audio Unit output format"
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
                "Failed to set track Audio Unit maximum frames per slice"
            )
            try checkStatus(AudioUnitInitialize(createdUnit), "Failed to initialize track Audio Unit")

            return createdUnit
        }

        private static func ensurePlugin(
            _ unit: AudioUnit,
            supports channelCount: Int,
            pluginName: String
        ) throws {
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

            guard infoStatus == noErr, size > 0 else {
                return
            }

            let infoCount = Int(size) / MemoryLayout<AUChannelInfo>.stride
            var channelInfos = Array(repeating: AUChannelInfo(inChannels: 0, outChannels: 0), count: infoCount)

            try channelInfos.withUnsafeMutableBytes { bytes in
                guard let baseAddress = bytes.baseAddress else {
                    throw AudioHostError("Failed to inspect \(pluginName) channel support.")
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
                    "Failed to inspect \(pluginName) channel support"
                )
            }

            let supported = channelInfos.contains { info in
                let input = Int(info.inChannels)
                let output = Int(info.outChannels)
                if input == channelCount && output == channelCount { return true }
                if input == -1 && output == -1 { return true }
                if input == -1 && output == -2 { return true }
                if input == channelCount && output == -1 { return true }
                if input == -1 && output == channelCount { return true }
                return false
            }

            if !supported {
                throw AudioHostError("\(pluginName) does not support \(channelCount)-channel track processing.")
            }
        }
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

    private var inputUnit: AudioUnit?
    private var outputUnit: AudioUnit?
    private var configuration: MultiTrackHostConfiguration?
    private var trackRuntimes: [TrackRuntime] = []
    private var captureBufferList: UnsafeMutableAudioBufferListPointer?
    private var captureChannelBuffers: [UnsafeMutablePointer<Float>] = []
    private var maxFramesPerSlice: UInt32 = 0
    private var audioDropoutCounter = SAHAtomicCounter()
    private var droppedFrameCounter = SAHAtomicCounter()
    private var nextExpectedInputSampleTime: Double?
    private var nextExpectedOutputSampleTime: Double?
    private let priorityController = AudioHostingPriorityController()

    deinit {
        stop()
    }

    func start(configuration: MultiTrackHostConfiguration) throws {
        stop()
        SAHAtomicCounterReset(&audioDropoutCounter)
        SAHAtomicCounterReset(&droppedFrameCounter)
        nextExpectedInputSampleTime = nil
        nextExpectedOutputSampleTime = nil
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
            maxFramesPerSlice = UInt32(configuration.bufferSize)

            try prepareCaptureBuffers(inputChannelCount: configuration.inputDevice.inputChannelCount)

            let availablePlugins = try AudioHostController().availablePlugins()

            trackRuntimes = try configuration.tracks.map { track in
                let plugin = track.pluginID.flatMap { id in
                    availablePlugins.first { $0.id == id }
                }
                return try TrackRuntime(
                    configuration: track,
                    plugin: plugin,
                    sampleRate: configuration.inputDevice.nominalSampleRate,
                    hardwareBufferSize: configuration.bufferSize,
                    internalBufferFrames: configuration.latencyBufferSettings.internalFrames(
                        for: track.latencyClass,
                        hardwareBufferSize: configuration.bufferSize
                    )
                )
            }

            try createAndConfigureIOUnits(for: configuration)

            if let outputUnit {
                try checkStatus(AudioOutputUnitStart(outputUnit), "Failed to start multi-track output audio")
            }
            if let inputUnit {
                try checkStatus(AudioOutputUnitStart(inputUnit), "Failed to start multi-track input audio")
            }
        } catch {
            stop()
            throw error
        }
    }

    func audioDropoutCount() -> UInt64 {
        let controllerCount = SAHAtomicCounterLoad(&audioDropoutCounter)
        return trackRuntimes.reduce(controllerCount) { partialResult, runtime in
            partialResult + runtime.audioDropoutCount()
        }
    }

    func droppedFrameCount() -> UInt64 {
        let controllerCount = SAHAtomicCounterLoad(&droppedFrameCounter)
        return trackRuntimes.reduce(controllerCount) { partialResult, runtime in
            partialResult + runtime.droppedFrameCount()
        }
    }

    func resetDropoutCounters() {
        SAHAtomicCounterReset(&audioDropoutCounter)
        SAHAtomicCounterReset(&droppedFrameCounter)
        nextExpectedInputSampleTime = nil
        nextExpectedOutputSampleTime = nil
        for runtime in trackRuntimes {
            runtime.resetDropoutCounters()
        }
    }

    func stop() {
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
        trackRuntimes.removeAll()

        for pointer in captureChannelBuffers {
            pointer.deallocate()
        }
        captureChannelBuffers.removeAll()
        captureBufferList?.unsafeMutablePointer.deallocate()
        captureBufferList = nil

        configuration = nil
        maxFramesPerSlice = 0
        nextExpectedInputSampleTime = nil
        nextExpectedOutputSampleTime = nil
        priorityController.deactivate()
    }

    private func prepareCaptureBuffers(inputChannelCount: Int) throws {
        captureBufferList?.unsafeMutablePointer.deallocate()
        captureBufferList = nil
        for pointer in captureChannelBuffers {
            pointer.deallocate()
        }
        captureChannelBuffers.removeAll()

        guard let configuration else { return }

        captureBufferList = AudioBufferList.allocate(maximumBuffers: inputChannelCount)
        captureBufferList?.count = inputChannelCount

        for channelIndex in 0..<inputChannelCount {
            let pointer = UnsafeMutablePointer<Float>.allocate(capacity: configuration.bufferSize)
            captureChannelBuffers.append(pointer)
            captureBufferList?[channelIndex].mNumberChannels = 1
            captureBufferList?[channelIndex].mDataByteSize = UInt32(configuration.bufferSize * MemoryLayout<Float>.size)
            captureBufferList?[channelIndex].mData = UnsafeMutableRawPointer(pointer)
        }
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
            AudioUnitSetProperty(inputUnit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &inputCallback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)),
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

        for runtime in trackRuntimes {
            runtime.enqueueInput(captureBuffers: captureBufferList, frameCount: inNumberFrames)
        }

        return noErr
    }

    private func handleOutputCallback(
        inTimeStamp: UnsafePointer<AudioTimeStamp>?,
        inNumberFrames: UInt32,
        ioData: UnsafeMutablePointer<AudioBufferList>?
    ) -> OSStatus {
        guard let ioData else { return noErr }
        updateExpectedSampleTime(
            with: inTimeStamp,
            frameCount: inNumberFrames,
            expectedSampleTime: &nextExpectedOutputSampleTime
        )

        let outputBuffers = UnsafeMutableAudioBufferListPointer(ioData)
        let frameCount = Int(inNumberFrames)
        let bytes = UInt32(frameCount * MemoryLayout<Float>.size)

        for bufferIndex in 0..<outputBuffers.count {
            outputBuffers[bufferIndex].mDataByteSize = bytes
            if let destination = outputBuffers[bufferIndex].mData?.assumingMemoryBound(to: Float.self) {
                for frame in 0..<frameCount {
                    destination[frame] = 0
                }
            }
        }


        for runtime in trackRuntimes {
            runtime.mixOutput(into: outputBuffers, hardwareFrames: frameCount)
        }

        return noErr
    }
}
