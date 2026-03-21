import Accelerate
import AudioToolbox
import CoreAudio
import Foundation

final class MultiTrackAudioHostController: @unchecked Sendable {
    private final class SharedInputChannelBuffer {
        var ring = SAHFloatRingBuffer()

        deinit {
            SAHFloatRingBufferDeinit(&ring)
        }
    }

    private final class SharedOutputChannelBuffer {
        var ring = SAHFloatRingBuffer()

        deinit {
            SAHFloatRingBufferDeinit(&ring)
        }
    }

    private final class TrackRuntime: @unchecked Sendable {
        let configuration: MultiTrackTrackConfiguration
        let processingFrames: Int
        let sampleRate: Double

        private var effectUnit: AudioUnit?
        private var wetBufferList: UnsafeMutableAudioBufferListPointer?
        private let inputSource1: SharedInputChannelBuffer
        private let inputSource2: SharedInputChannelBuffer?
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
        private var peakOutputRingOccupancyFrames = SAHAtomicCounter()

        init(
            configuration: MultiTrackTrackConfiguration,
            plugin: AudioUnitPluginInfo?,
            sampleRate: Double,
            hardwareBufferSize: Int,
            internalBufferFrames: Int,
            inputSource1: SharedInputChannelBuffer,
            inputSource2: SharedInputChannelBuffer?
        ) throws {
            self.configuration = configuration
            self.sampleRate = sampleRate
            self.inputSource1 = inputSource1
            self.inputSource2 = inputSource2
            self.processingFrames = configuration.latencyClass == .realtime
                ? hardwareBufferSize
                : max(hardwareBufferSize, internalBufferFrames)
            SAHAtomicCounterReset(&audioDropoutCounter)
            SAHAtomicCounterReset(&droppedFrameCounter)
            SAHAtomicCounterReset(&peakOutputRingOccupancyFrames)

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
            SAHFloatRingBufferDeinit(&outputRing1)
            SAHFloatRingBufferDeinit(&outputRing2)
        }

        func audioDropoutCount() -> UInt64 {
            SAHAtomicCounterLoad(&audioDropoutCounter)
        }

        func droppedFrameCount() -> UInt64 {
            SAHAtomicCounterLoad(&droppedFrameCounter)
        }

        func peakOutputRingOccupancy() -> UInt64 {
            SAHAtomicCounterLoad(&peakOutputRingOccupancyFrames)
        }

        func hasBufferedOutput(frames: Int) -> Bool {
            guard configuration.latencyClass != .realtime else { return false }
            let requestedFrames = UInt32(frames)
            let available1 = SAHFloatRingBufferAvailableRead(&outputRing1)
            let available2 = configuration.channelCount == 1 ? available1 : SAHFloatRingBufferAvailableRead(&outputRing2)
            return available1 >= requestedFrames && available2 >= requestedFrames
        }

        func resetDropoutCounters() {
            SAHAtomicCounterReset(&audioDropoutCounter)
            SAHAtomicCounterReset(&droppedFrameCounter)
            SAHAtomicCounterReset(&peakOutputRingOccupancyFrames)
        }

        func signalInputReady() {
            if configuration.latencyClass != .realtime {
                workerWakeup.signal()
            }
        }

        var isRealtime: Bool {
            configuration.latencyClass == .realtime
        }

        var outputChannelCount: Int {
            configuration.channelCount
        }

        var outputStartChannelOffset: Int {
            configuration.outputStartChannel - 1
        }

        func mixRealtimeOutput(into outputBuffers: UnsafeMutableAudioBufferListPointer, hardwareFrames: Int) {
            guard configuration.isEnabled, configuration.latencyClass == .realtime else { return }
            renderRealtime(frames: hardwareFrames)

            let outputChannelOffset = configuration.outputStartChannel - 1
            if let destination = outputBuffers[outputChannelOffset].mData?.assumingMemoryBound(to: Float.self),
               let source = outputScratch1 {
                accumulateAudioBuffer(source, into: destination, frameCount: hardwareFrames)
            }

            if configuration.channelCount == 2,
               let destination = outputBuffers[outputChannelOffset + 1].mData?.assumingMemoryBound(to: Float.self),
               let source = outputScratch2 {
                accumulateAudioBuffer(source, into: destination, frameCount: hardwareFrames)
            }
        }

        func mixBufferedOutput(
            into premixBuffers: [UnsafeMutablePointer<Float>],
            frames: Int
        ) {
            guard configuration.isEnabled, configuration.latencyClass != .realtime else { return }
            drainBufferedOutput(frames: frames)

            let outputChannelOffset = configuration.outputStartChannel - 1
            if outputChannelOffset < premixBuffers.count, let source = outputScratch1 {
                accumulateAudioBuffer(source, into: premixBuffers[outputChannelOffset], frameCount: frames)
            }

            if configuration.channelCount == 2,
               outputChannelOffset + 1 < premixBuffers.count,
               let source = outputScratch2 {
                accumulateAudioBuffer(source, into: premixBuffers[outputChannelOffset + 1], frameCount: frames)
            }
        }

        private func prepareBuffers() throws {
            let ringCapacity = UInt32(max(processingFrames * 32, 4096))

            guard SAHFloatRingBufferInit(&outputRing1, ringCapacity) else {
                throw AudioHostError("Failed to allocate multi-track output buffer.")
            }

            if configuration.channelCount == 2 {
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
            let receivedFrames1 = SAHFloatRingBufferRead(&inputSource1.ring, inputScratch1, requestedFrames)
            var droppedFrames = requestedFrames - receivedFrames1
            if Int(receivedFrames1) < frames {
                inputScratch1.advanced(by: Int(receivedFrames1)).update(repeating: 0, count: frames - Int(receivedFrames1))
            }

            if configuration.channelCount == 2, let inputScratch2, let inputSource2 {
                let receivedFrames2 = SAHFloatRingBufferRead(&inputSource2.ring, inputScratch2, requestedFrames)
                droppedFrames = max(droppedFrames, requestedFrames - receivedFrames2)
                if Int(receivedFrames2) < frames {
                    inputScratch2.advanced(by: Int(receivedFrames2)).update(repeating: 0, count: frames - Int(receivedFrames2))
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
                outputScratch1.advanced(by: frames).update(repeating: 0, count: max(0, processingFrames - frames))
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
                outputScratch1.advanced(by: Int(receivedFrames1)).update(repeating: 0, count: frames - Int(receivedFrames1))
            }

            if configuration.channelCount == 2, let outputScratch2 {
                let receivedFrames2 = SAHFloatRingBufferRead(&outputRing2, outputScratch2, requestedFrames)
                droppedFrames = max(droppedFrames, requestedFrames - receivedFrames2)
                if Int(receivedFrames2) < frames {
                    outputScratch2.advanced(by: Int(receivedFrames2)).update(repeating: 0, count: frames - Int(receivedFrames2))
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
            promoteCurrentThreadToAudioWorkerQoS()

            while shouldWorkerContinue() && !Thread.current.isCancelled {
                let frames = UInt32(processingFrames)
                let hasInput1 = SAHFloatRingBufferAvailableRead(&inputSource1.ring) >= frames
                let hasOutput1 = SAHFloatRingBufferAvailableWrite(&outputRing1) >= frames
                let hasInput2 = configuration.channelCount == 1 || (inputSource2.map { SAHFloatRingBufferAvailableRead(&$0.ring) >= frames } ?? false)
                let hasOutput2 = configuration.channelCount == 1 || SAHFloatRingBufferAvailableWrite(&outputRing2) >= frames

                guard hasInput1, hasOutput1, hasInput2, hasOutput2 else {
                    workerWakeup.wait()
                    continue
                }

                guard let inputScratch1, let outputScratch1 else {
                    return
                }

                _ = SAHFloatRingBufferRead(&inputSource1.ring, inputScratch1, frames)
                var inputScratch2Pointer: UnsafeMutablePointer<Float>?
                if configuration.channelCount == 2, let inputScratch2, let inputSource2 {
                    _ = SAHFloatRingBufferRead(&inputSource2.ring, inputScratch2, frames)
                    inputScratch2Pointer = inputScratch2
                }

                _ = render(
                    frameCount: processingFrames,
                    input1: inputScratch1,
                    input2: inputScratch2Pointer
                )
                let writtenFrames1 = SAHFloatRingBufferWrite(&outputRing1, outputScratch1, frames)
                SAHAtomicCounterStoreMax(&peakOutputRingOccupancyFrames, UInt64(SAHFloatRingBufferAvailableRead(&outputRing1)))
                var droppedFrames = frames - writtenFrames1
                if configuration.channelCount == 2, let outputScratch2 {
                    let writtenFrames2 = SAHFloatRingBufferWrite(&outputRing2, outputScratch2, frames)
                    SAHAtomicCounterStoreMax(&peakOutputRingOccupancyFrames, UInt64(SAHFloatRingBufferAvailableRead(&outputRing2)))
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
            clearAudioBuffer(outputScratch1, frameCount: frames)
            if configuration.channelCount == 2, let outputScratch2 {
                clearAudioBuffer(outputScratch2, frameCount: frames)
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
    private var bufferedTrackRuntimes: [TrackRuntime] = []
    private var realtimeTrackRuntimes: [TrackRuntime] = []
    private var captureBufferList: UnsafeMutableAudioBufferListPointer?
    private var captureChannelBuffers: [UnsafeMutablePointer<Float>] = []
    private var sharedInputChannelBuffers: [SharedInputChannelBuffer] = []
    private var sharedPremixOutputBuffers: [SharedOutputChannelBuffer] = []
    private var premixScratchBuffers: [UnsafeMutablePointer<Float>] = []
    private var maxFramesPerSlice: UInt32 = 0
    private var callbackFrameCapacity: Int = 0
    private var audioDropoutCounter = SAHAtomicCounter()
    private var droppedFrameCounter = SAHAtomicCounter()
    private var peakInputCallbackFrames = SAHAtomicCounter()
    private var peakOutputCallbackFrames = SAHAtomicCounter()
    private var peakSharedInputRingOccupancyFrames = SAHAtomicCounter()
    private var peakPremixOutputRingOccupancyFrames = SAHAtomicCounter()
    private var nextExpectedInputSampleTime: Double?
    private var nextExpectedOutputSampleTime: Double?
    private let priorityController = AudioHostingPriorityController()
    private let runtimeStateLock = NSLock()
    private let deviceObserver = AudioHardwareChangeObserver()
    private let premixStateLock = NSLock()
    private let premixWakeup = AudioWorkerWakeup()
    private let premixExitGroup = DispatchGroup()
    private var runtimeStatus: String?
    private var premixThread: Thread?
    private var shouldRunPremixWorker = false
    private var premixOutputPrimed = false
    private var sharedInputRingCapacityFrames = 0
    private var peakTrackOutputRingCapacityFrames = 0
    private var premixOutputRingCapacityFrames = 0

    deinit {
        stop()
    }

    func start(configuration: MultiTrackHostConfiguration) throws {
        stop()
        SAHAtomicCounterReset(&audioDropoutCounter)
        SAHAtomicCounterReset(&droppedFrameCounter)
        resetTelemetry()
        nextExpectedInputSampleTime = nil
        nextExpectedOutputSampleTime = nil
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

            try prepareCaptureBuffers(
                inputChannelCount: configuration.inputDevice.inputChannelCount,
                ringCapacityFrames: maxInternalFrames
            )

            let availablePlugins = try AudioHostController().availablePlugins()

            trackRuntimes = try configuration.tracks.map { track in
                let plugin = track.pluginID.flatMap { id in
                    availablePlugins.first { $0.id == id }
                }
                let inputChannelOffset = track.inputStartChannel - 1
                return try TrackRuntime(
                    configuration: track,
                    plugin: plugin,
                    sampleRate: configuration.inputDevice.nominalSampleRate,
                    hardwareBufferSize: configuration.bufferSize,
                    internalBufferFrames: configuration.latencyBufferSettings.internalFrames(
                        for: track.latencyClass,
                        hardwareBufferSize: configuration.bufferSize
                    ),
                    inputSource1: sharedInputChannelBuffers[inputChannelOffset],
                    inputSource2: track.channelCount == 2 ? sharedInputChannelBuffers[inputChannelOffset + 1] : nil
                )
            }
            bufferedTrackRuntimes = trackRuntimes.filter { !$0.isRealtime }
            realtimeTrackRuntimes = trackRuntimes.filter(\.isRealtime)
            peakTrackOutputRingCapacityFrames = configuration.tracks.reduce(0) { partialResult, track in
                let processingFrames = max(
                    configuration.bufferSize,
                    configuration.latencyBufferSettings.internalFrames(
                        for: track.latencyClass,
                        hardwareBufferSize: configuration.bufferSize
                    )
                )
                return max(partialResult, max(processingFrames * 32, 4096))
            }

            try createAndConfigureIOUnits(for: configuration)
            let actualInputMaxFrames = try actualMaximumFramesPerSlice(for: inputUnit)
            let actualOutputMaxFrames = try actualMaximumFramesPerSlice(for: outputUnit)
            callbackFrameCapacity = allocatedFrameCapacity(
                actualMaximumFrames: max(actualInputMaxFrames, actualOutputMaxFrames),
                nominalBufferSize: configuration.bufferSize
            )
            try preparePremixOutputBuffers(outputChannelCount: configuration.outputDevice.outputChannelCount)
            installDeviceObservers(for: configuration)
            if !bufferedTrackRuntimes.isEmpty {
                startPremixWorker()
            }

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
        resetTelemetry()
        nextExpectedInputSampleTime = nil
        nextExpectedOutputSampleTime = nil
        for runtime in trackRuntimes {
            runtime.resetDropoutCounters()
        }
    }

    func runtimeStatusMessage() -> String? {
        runtimeStateLock.lock()
        defer { runtimeStateLock.unlock() }
        return runtimeStatus
    }

    func telemetrySnapshot() -> AudioEngineTelemetrySnapshot {
        let peakTrackOutputOccupancy = trackRuntimes.reduce(UInt64(0)) { partialResult, runtime in
            max(partialResult, runtime.peakOutputRingOccupancy())
        }
        let peakOutputOccupancy = max(peakTrackOutputOccupancy, SAHAtomicCounterLoad(&peakPremixOutputRingOccupancyFrames))
        return AudioEngineTelemetrySnapshot(
            peakInputCallbackFrames: SAHAtomicCounterLoad(&peakInputCallbackFrames),
            peakOutputCallbackFrames: SAHAtomicCounterLoad(&peakOutputCallbackFrames),
            peakEffectRenderFrames: 0,
            peakInputRingOccupancyFrames: SAHAtomicCounterLoad(&peakSharedInputRingOccupancyFrames),
            peakOutputRingOccupancyFrames: peakOutputOccupancy,
            inputRingCapacityFrames: sharedInputRingCapacityFrames,
            outputRingCapacityFrames: max(peakTrackOutputRingCapacityFrames, premixOutputRingCapacityFrames)
        )
    }

    func stop() {
        stopPremixWorker()
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
        trackRuntimes.removeAll()
        bufferedTrackRuntimes.removeAll()
        realtimeTrackRuntimes.removeAll()
        sharedInputChannelBuffers.removeAll()
        sharedPremixOutputBuffers.removeAll()

        for pointer in captureChannelBuffers {
            pointer.deallocate()
        }
        captureChannelBuffers.removeAll()
        for pointer in premixScratchBuffers {
            pointer.deallocate()
        }
        premixScratchBuffers.removeAll()
        captureBufferList?.unsafeMutablePointer.deallocate()
        captureBufferList = nil

        configuration = nil
        maxFramesPerSlice = 0
        callbackFrameCapacity = 0
        sharedInputRingCapacityFrames = 0
        peakTrackOutputRingCapacityFrames = 0
        premixOutputRingCapacityFrames = 0
        nextExpectedInputSampleTime = nil
        nextExpectedOutputSampleTime = nil
        clearRuntimeStatus()
        priorityController.deactivate()
    }

    private func prepareCaptureBuffers(inputChannelCount: Int, ringCapacityFrames: Int) throws {
        captureBufferList?.unsafeMutablePointer.deallocate()
        captureBufferList = nil
        for pointer in captureChannelBuffers {
            pointer.deallocate()
        }
        captureChannelBuffers.removeAll()
        sharedInputChannelBuffers.removeAll()

        guard let configuration else { return }

        captureBufferList = AudioBufferList.allocate(maximumBuffers: inputChannelCount)
        captureBufferList?.count = inputChannelCount

        for channelIndex in 0..<inputChannelCount {
            let captureFrameCapacity = allocatedFrameCapacity(
                actualMaximumFrames: Int(maxFramesPerSlice),
                nominalBufferSize: configuration.bufferSize
            )
            let pointer = UnsafeMutablePointer<Float>.allocate(capacity: captureFrameCapacity)
            captureChannelBuffers.append(pointer)
            let channelBuffer = SharedInputChannelBuffer()
            guard SAHFloatRingBufferInit(&channelBuffer.ring, UInt32(max(ringCapacityFrames * 32, 4096))) else {
                throw AudioHostError("Failed to allocate shared input channel buffer.")
            }
            sharedInputRingCapacityFrames = max(sharedInputRingCapacityFrames, Int(channelBuffer.ring.capacity))
            sharedInputChannelBuffers.append(channelBuffer)
            captureBufferList?[channelIndex].mNumberChannels = 1
            captureBufferList?[channelIndex].mDataByteSize = UInt32(captureFrameCapacity * MemoryLayout<Float>.size)
            captureBufferList?[channelIndex].mData = UnsafeMutableRawPointer(pointer)
        }
    }

    private func preparePremixOutputBuffers(outputChannelCount: Int) throws {
        for pointer in premixScratchBuffers {
            pointer.deallocate()
        }
        premixScratchBuffers.removeAll()
        sharedPremixOutputBuffers.removeAll()
        premixOutputPrimed = false

        guard let configuration else { return }
        let ringCapacity = UInt32(max(configuration.bufferSize * 32, 4096))

        for _ in 0..<outputChannelCount {
            let buffer = SharedOutputChannelBuffer()
            guard SAHFloatRingBufferInit(&buffer.ring, ringCapacity) else {
                throw AudioHostError("Failed to allocate premix output buffer.")
            }
            sharedPremixOutputBuffers.append(buffer)
            premixScratchBuffers.append(UnsafeMutablePointer<Float>.allocate(capacity: configuration.bufferSize))
            premixOutputRingCapacityFrames = max(premixOutputRingCapacityFrames, Int(buffer.ring.capacity))
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

        for (index, sharedBuffer) in sharedInputChannelBuffers.enumerated() {
            guard let source = captureBufferList[index].mData?.assumingMemoryBound(to: Float.self) else {
                recordDroppedFrames(inNumberFrames)
                continue
            }
            let writtenFrames = SAHFloatRingBufferWrite(&sharedBuffer.ring, source, inNumberFrames)
            SAHAtomicCounterStoreMax(&peakSharedInputRingOccupancyFrames, UInt64(SAHFloatRingBufferAvailableRead(&sharedBuffer.ring)))
            if writtenFrames < inNumberFrames {
                recordDroppedFrames(inNumberFrames - writtenFrames)
            }
        }

        for runtime in trackRuntimes {
            runtime.signalInputReady()
        }

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
        if runtimeStatusMessage() != nil {
            return noErr
        }
        SAHAtomicCounterStoreMax(&peakOutputCallbackFrames, UInt64(inNumberFrames))
        updateExpectedSampleTime(
            with: inTimeStamp,
            frameCount: inNumberFrames,
            expectedSampleTime: &nextExpectedOutputSampleTime
        )

        drainPremixedOutput(into: outputBuffers, frameCount: frameCount)

        for runtime in realtimeTrackRuntimes {
            runtime.mixRealtimeOutput(into: outputBuffers, hardwareFrames: frameCount)
        }
        premixWakeup.signal()

        return noErr
    }
}

private extension MultiTrackAudioHostController {
    func startPremixWorker() {
        premixStateLock.lock()
        shouldRunPremixWorker = true
        premixStateLock.unlock()
        premixExitGroup.enter()

        let premixThread = Thread { [weak self] in
            defer {
                self?.premixExitGroup.leave()
            }
            self?.premixWorkerLoop()
        }
        premixThread.name = "SimpleAUHost.MultiTrackPremix"
        premixThread.qualityOfService = .userInitiated
        self.premixThread = premixThread
        premixThread.start()
    }

    func stopPremixWorker() {
        premixStateLock.lock()
        shouldRunPremixWorker = false
        premixStateLock.unlock()

        premixThread?.cancel()
        premixWakeup.signal()
        if premixThread != nil {
            premixExitGroup.wait()
        }
        premixThread = nil
    }

    func shouldPremixWorkerContinue() -> Bool {
        premixStateLock.lock()
        defer { premixStateLock.unlock() }
        return shouldRunPremixWorker
    }

    func premixWorkerLoop() {
        guard let configuration, !bufferedTrackRuntimes.isEmpty else { return }
        promoteCurrentThreadToAudioWorkerQoS()
        let frames = configuration.bufferSize

        while shouldPremixWorkerContinue() && !Thread.current.isCancelled {
            if runtimeStatusMessage() != nil {
                return
            }

            let hasRingSpace = sharedPremixOutputBuffers.allSatisfy {
                SAHFloatRingBufferAvailableWrite(&$0.ring) >= UInt32(frames)
            }
            let hasTrackOutput = bufferedTrackRuntimes.contains { runtime in
                runtime.hasBufferedOutput(frames: frames)
            }

            guard hasRingSpace, hasTrackOutput else {
                premixWakeup.wait()
                continue
            }

            for pointer in premixScratchBuffers {
                clearAudioBuffer(pointer, frameCount: frames)
            }

            for runtime in bufferedTrackRuntimes {
                runtime.mixBufferedOutput(into: premixScratchBuffers, frames: frames)
            }

            for (index, buffer) in sharedPremixOutputBuffers.enumerated() {
                let writtenFrames = SAHFloatRingBufferWrite(&buffer.ring, premixScratchBuffers[index], UInt32(frames))
                SAHAtomicCounterStoreMax(&peakPremixOutputRingOccupancyFrames, UInt64(SAHFloatRingBufferAvailableRead(&buffer.ring)))
                if writtenFrames < UInt32(frames) {
                    recordDroppedFrames(UInt32(frames) - writtenFrames)
                }
            }
        }
    }

    func drainPremixedOutput(into outputBuffers: UnsafeMutableAudioBufferListPointer, frameCount: Int) {
        guard !sharedPremixOutputBuffers.isEmpty else { return }
        let requestedFrames = UInt32(frameCount)
        let prerollFrames = UInt32(max(configuration?.bufferSize ?? frameCount, frameCount * 2))
        let minAvailable = sharedPremixOutputBuffers.reduce(UInt32.max) { partialResult, buffer in
            min(partialResult, SAHFloatRingBufferAvailableRead(&buffer.ring))
        }

        if !premixOutputPrimed {
            guard minAvailable >= prerollFrames else {
                return
            }
            premixOutputPrimed = true
        }

        var droppedFrames: UInt32 = 0
        for index in 0..<min(outputBuffers.count, sharedPremixOutputBuffers.count) {
            guard let destination = outputBuffers[index].mData?.assumingMemoryBound(to: Float.self) else {
                continue
            }
            let readFrames = SAHFloatRingBufferRead(&sharedPremixOutputBuffers[index].ring, destination, requestedFrames)
            SAHAtomicCounterStoreMax(&peakPremixOutputRingOccupancyFrames, UInt64(SAHFloatRingBufferAvailableRead(&sharedPremixOutputBuffers[index].ring)))
            if readFrames < requestedFrames {
                droppedFrames = max(droppedFrames, requestedFrames - readFrames)
                destination.advanced(by: Int(readFrames)).update(repeating: 0, count: frameCount - Int(readFrames))
            }
        }

        if droppedFrames > 0 {
            premixOutputPrimed = false
            recordDroppedFrames(droppedFrames)
        }
    }

    func resetTelemetry() {
        SAHAtomicCounterReset(&peakInputCallbackFrames)
        SAHAtomicCounterReset(&peakOutputCallbackFrames)
        SAHAtomicCounterReset(&peakSharedInputRingOccupancyFrames)
        SAHAtomicCounterReset(&peakPremixOutputRingOccupancyFrames)
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

private func accumulateAudioBuffer(
    _ source: UnsafeMutablePointer<Float>,
    into destination: UnsafeMutablePointer<Float>,
    frameCount: Int
) {
    guard frameCount > 0 else { return }
    vDSP_vadd(source, 1, destination, 1, destination, 1, vDSP_Length(frameCount))
}
