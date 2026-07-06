@preconcurrency import AudioToolbox
import CoreAudio
import Foundation

extension MultiTrackAudioHostController {
    final class TrackRuntime: @unchecked Sendable {
        struct PluginRuntime {
            let insert: MultiTrackTrackConfiguration.PluginInsert
            let plugin: AudioUnitPluginInfo
            let unit: AudioUnit
        }

        let configuration: MultiTrackTrackConfiguration
        let processingFrames: Int
        let renderFrameCapacity: Int
        let broadcastPrerollMultiplier: Int
        let sampleRate: Double

        var plugins: [PluginRuntime] = []
        private var wetBufferList: UnsafeMutableAudioBufferListPointer?
        private let realtimeInputRing1 = FloatRingBuffer()
        private let realtimeInputRing2 = FloatRingBuffer()
        private let bufferedOutputRing1 = FloatRingBuffer()
        private let bufferedOutputRing2 = FloatRingBuffer()
        private var inputScratch1: UnsafeMutablePointer<Float>?
        private var inputScratch2: UnsafeMutablePointer<Float>?
        private var outputScratch1: UnsafeMutablePointer<Float>?
        private var outputScratch2: UnsafeMutablePointer<Float>?
        private var intermediateScratch1: UnsafeMutablePointer<Float>?
        private var intermediateScratch2: UnsafeMutablePointer<Float>?
        private var currentInputSource1: UnsafeMutablePointer<Float>?
        private var currentInputSource2: UnsafeMutablePointer<Float>?
        private var bufferedOutputPrimed = false
        private var renderSampleTime: Double = 0
        private let audioDropoutCounter = AtomicCounter()
        private let droppedFrameCounter = AtomicCounter()
        private let peakInputRingOccupancyFrames = AtomicCounter()
        private let peakOutputRingOccupancyFrames = AtomicCounter()
        private let peakRenderDurationNanoseconds = AtomicCounter()
        private let totalRenderDurationNanoseconds = AtomicCounter()
        private let renderPassCount = AtomicCounter()

        init(
            configuration: MultiTrackTrackConfiguration,
            plugins: [(MultiTrackTrackConfiguration.PluginInsert, AudioUnitPluginInfo)],
            sampleRate: Double,
            hardwareBufferSize: Int,
            internalBufferFrames: Int,
            broadcastPrerollMultiplier: Int,
            maximumRenderFrames: Int
        ) throws {
            self.configuration = configuration
            self.sampleRate = sampleRate
            self.processingFrames = configuration.latencyClass == .realtime
                ? hardwareBufferSize
                : max(hardwareBufferSize, internalBufferFrames)
            self.renderFrameCapacity = max(self.processingFrames, maximumRenderFrames)
            self.broadcastPrerollMultiplier = max(1, broadcastPrerollMultiplier)

            try prepareBuffers(hardwareBufferSize: hardwareBufferSize)

            var createdPlugins: [PluginRuntime] = []
            for (insert, plugin) in plugins {
                let unit = try Self.createEffectUnit(
                    plugin: plugin,
                    sampleRate: sampleRate,
                    channelCount: configuration.channelCount,
                    maximumFrames: renderFrameCapacity,
                    owner: self
                )
                createdPlugins.append(PluginRuntime(insert: insert, plugin: plugin, unit: unit))
            }
            self.plugins = createdPlugins

            do {
                try applySerializedPluginStates()
            } catch {
                for pluginRuntime in createdPlugins {
                    AudioUnitUninitialize(pluginRuntime.unit)
                    AudioComponentInstanceDispose(pluginRuntime.unit)
                }
                throw error
            }
        }

        deinit {
            for plugin in plugins {
                AudioUnitUninitialize(plugin.unit)
                AudioComponentInstanceDispose(plugin.unit)
            }
            wetBufferList?.unsafeMutablePointer.deallocate()
            inputScratch1?.deallocate()
            inputScratch2?.deallocate()
            outputScratch1?.deallocate()
            outputScratch2?.deallocate()
            intermediateScratch1?.deallocate()
            intermediateScratch2?.deallocate()
        }

        func audioDropoutCount() -> UInt64 {
            audioDropoutCounter.load()
        }

        func droppedFrameCount() -> UInt64 {
            droppedFrameCounter.load()
        }

        func pluginLatencyFrames() -> Int {
            plugins.reduce(0) { total, pluginRuntime in
                total + Self.latencyFrames(for: pluginRuntime.unit, sampleRate: sampleRate)
            }
        }

        func peakInputRingOccupancy() -> UInt64 {
            peakInputRingOccupancyFrames.load()
        }

        func peakOutputRingOccupancy() -> UInt64 {
            peakOutputRingOccupancyFrames.load()
        }

        func peakRenderDurationMicros() -> UInt64 {
            peakRenderDurationNanoseconds.load() / 1_000
        }

        func averageRenderDurationMicros() -> UInt64 {
            let passes = renderPassCount.load()
            guard passes > 0 else { return 0 }
            return (totalRenderDurationNanoseconds.load() / passes) / 1_000
        }

        func hasBufferedOutput(frames: Int) -> Bool {
            guard configuration.latencyClass != .realtime else { return false }
            let requestedFrames = bufferedOutputPrimed
                ? UInt32(frames)
                : bufferedOutputPrerollFrames(stagingFrames: frames)
            let available1 = bufferedOutputRing1.availableRead()
            let available2 = configuration.channelCount == 1 ? available1 : bufferedOutputRing2.availableRead()
            return available1 >= requestedFrames && available2 >= requestedFrames
        }

        func canAcceptBufferedInput(frames: Int) -> Bool {
            guard configuration.latencyClass != .realtime else { return false }
            let requestedFrames = UInt32(frames)
            let available1 = bufferedOutputRing1.availableWrite()
            let available2 = configuration.channelCount == 1 ? available1 : bufferedOutputRing2.availableWrite()
            return available1 >= requestedFrames && available2 >= requestedFrames
        }

        func resetDropoutCounters() {
            audioDropoutCounter.reset()
            droppedFrameCounter.reset()
        }

        var isRealtime: Bool {
            configuration.latencyClass == .realtime
        }

        var isBuffered: Bool {
            !isRealtime
        }

        var hasEffect: Bool {
            !plugins.isEmpty
        }

        var hasOpenablePluginEditor: Bool {
            !plugins.isEmpty
        }

        var inputStartChannelOffset: Int {
            configuration.inputStartChannel - 1
        }

        var inputChannelOffsets: [Int] {
            if configuration.channelCount == 2 {
                [inputStartChannelOffset, inputStartChannelOffset + 1]
            } else {
                [inputStartChannelOffset]
            }
        }

        var outputRingCapacityFrames: Int {
            if configuration.latencyClass == .realtime {
                max(Int(realtimeInputRing1.capacity), Int(realtimeInputRing2.capacity))
            } else {
                max(Int(bufferedOutputRing1.capacity), Int(bufferedOutputRing2.capacity))
            }
        }

        func estimatedLoadWeight() -> Int {
            let channelWeight = configuration.channelCount
            let pluginWeight = max(1, plugins.count * 4)
            let latencyWeight = configuration.latencyClass == .broadcast ? 2 : 1
            return channelWeight * pluginWeight * latencyWeight
        }

        func enqueueRealtimeInput(
            source1: UnsafePointer<Float>,
            source2: UnsafePointer<Float>?,
            frameCount: UInt32
        ) {
            guard configuration.latencyClass == .realtime else { return }
            let writtenFrames1 = realtimeInputRing1.write(from: source1, count: frameCount)
            peakInputRingOccupancyFrames.storeMax(UInt64(realtimeInputRing1.availableRead()))
            var droppedFrames = frameCount - writtenFrames1
            if configuration.channelCount == 2, let source2 {
                let writtenFrames2 = realtimeInputRing2.write(from: source2, count: frameCount)
                peakInputRingOccupancyFrames.storeMax(UInt64(realtimeInputRing2.availableRead()))
                droppedFrames = max(droppedFrames, frameCount - writtenFrames2)
            }
            if droppedFrames > 0 {
                recordDroppedFrames(droppedFrames)
            }
        }

        func mixRealtimeOutput(into outputBuffers: UnsafeMutableAudioBufferListPointer, hardwareFrames: Int) {
            guard configuration.isEnabled, configuration.latencyClass == .realtime else { return }
            let renderStart = currentUptimeNanoseconds()
            renderRealtime(frames: hardwareFrames)
            recordRenderDuration(currentUptimeNanoseconds() - renderStart)

            let outputChannelOffset = configuration.outputStartChannel - 1
            if let destination = outputBuffers[outputChannelOffset].mData?.assumingMemoryBound(to: Float.self),
               let source = outputScratch1 {
                destination.update(from: source, count: hardwareFrames)
            }

            if configuration.channelCount == 2,
               let destination = outputBuffers[outputChannelOffset + 1].mData?.assumingMemoryBound(to: Float.self),
               let source = outputScratch2 {
                destination.update(from: source, count: hardwareFrames)
            }
        }

        func renderBufferedOutput(
            input1: UnsafeMutablePointer<Float>,
            input2: UnsafeMutablePointer<Float>?
        ) {
            guard configuration.isEnabled, configuration.latencyClass != .realtime else { return }
            let renderStart = currentUptimeNanoseconds()
            _ = render(
                frameCount: processingFrames,
                input1: input1,
                input2: configuration.channelCount == 2 ? input2 : nil
            )
            recordRenderDuration(currentUptimeNanoseconds() - renderStart)

            guard let outputScratch1 else { return }
            let frames = UInt32(processingFrames)
            let writtenFrames1 = bufferedOutputRing1.write(from: outputScratch1, count: frames)
            peakOutputRingOccupancyFrames.storeMax(UInt64(bufferedOutputRing1.availableRead()))
            var droppedFrames = frames - writtenFrames1
            if configuration.channelCount == 2, let outputScratch2 {
                let writtenFrames2 = bufferedOutputRing2.write(from: outputScratch2, count: frames)
                peakOutputRingOccupancyFrames.storeMax(UInt64(bufferedOutputRing2.availableRead()))
                droppedFrames = max(droppedFrames, frames - writtenFrames2)
            }
            if droppedFrames > 0 {
                recordDroppedFrames(droppedFrames)
            }
        }

        func stageBufferedOutput(
            into stagedOutputBuffers: [UnsafeMutablePointer<Float>],
            frames: Int
        ) {
            guard configuration.isEnabled, configuration.latencyClass != .realtime else { return }
            drainBufferedOutput(frames: frames)

            let outputChannelOffset = configuration.outputStartChannel - 1
            if outputChannelOffset < stagedOutputBuffers.count, let source = outputScratch1 {
                stagedOutputBuffers[outputChannelOffset].update(from: source, count: frames)
            }

            if configuration.channelCount == 2,
               outputChannelOffset + 1 < stagedOutputBuffers.count,
               let source = outputScratch2 {
                stagedOutputBuffers[outputChannelOffset + 1].update(from: source, count: frames)
            }
        }

        private func prepareBuffers(hardwareBufferSize: Int) throws {
            let ringCapacity = UInt32(max(processingFrames * 32, 4096))

            if configuration.latencyClass == .realtime {
                let inputRingCapacity = UInt32(max(renderFrameCapacity * 32, 4096))
                guard realtimeInputRing1.initialize(minimumCapacity: inputRingCapacity) else {
                    throw AudioHostError("Failed to allocate multi-track realtime input buffer.")
                }
                if configuration.channelCount == 2 {
                    guard realtimeInputRing2.initialize(minimumCapacity: inputRingCapacity) else {
                        throw AudioHostError("Failed to allocate stereo realtime input buffer.")
                    }
                }
            } else {
                guard bufferedOutputRing1.initialize(minimumCapacity: ringCapacity) else {
                    throw AudioHostError("Failed to allocate multi-track output buffer.")
                }
                if configuration.channelCount == 2 {
                    guard bufferedOutputRing2.initialize(minimumCapacity: ringCapacity) else {
                        throw AudioHostError("Failed to allocate stereo output buffer.")
                    }
                }
            }

            inputScratch1 = UnsafeMutablePointer<Float>.allocate(capacity: renderFrameCapacity)
            outputScratch1 = UnsafeMutablePointer<Float>.allocate(capacity: renderFrameCapacity)
            intermediateScratch1 = UnsafeMutablePointer<Float>.allocate(capacity: renderFrameCapacity)

            if configuration.channelCount == 2 {
                inputScratch2 = UnsafeMutablePointer<Float>.allocate(capacity: renderFrameCapacity)
                outputScratch2 = UnsafeMutablePointer<Float>.allocate(capacity: renderFrameCapacity)
                intermediateScratch2 = UnsafeMutablePointer<Float>.allocate(capacity: renderFrameCapacity)
            }

            wetBufferList = AudioBufferList.allocate(maximumBuffers: configuration.channelCount)
            wetBufferList?.count = configuration.channelCount

            wetBufferList?[0].mNumberChannels = 1
            wetBufferList?[0].mDataByteSize = UInt32(renderFrameCapacity * MemoryLayout<Float>.size)
            wetBufferList?[0].mData = UnsafeMutableRawPointer(outputScratch1)

            if configuration.channelCount == 2 {
                wetBufferList?[1].mNumberChannels = 1
                wetBufferList?[1].mDataByteSize = UInt32(renderFrameCapacity * MemoryLayout<Float>.size)
                wetBufferList?[1].mData = UnsafeMutableRawPointer(outputScratch2)
            }
        }

        private func renderRealtime(frames: Int) {
            guard let inputScratch1, let outputScratch1 else { return }

            let requestedFrames = UInt32(frames)
            let receivedFrames1 = realtimeInputRing1.read(into: inputScratch1, count: requestedFrames)
            var droppedFrames = requestedFrames - receivedFrames1
            if Int(receivedFrames1) < frames {
                inputScratch1.advanced(by: Int(receivedFrames1)).update(repeating: 0, count: frames - Int(receivedFrames1))
            }

            if configuration.channelCount == 2, let inputScratch2 {
                let receivedFrames2 = realtimeInputRing2.read(into: inputScratch2, count: requestedFrames)
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
            let prerollFrames = bufferedOutputPrerollFrames(stagingFrames: frames)
            let availableFrames1 = bufferedOutputRing1.availableRead()
            let availableFrames2 = configuration.channelCount == 1
                ? availableFrames1
                : bufferedOutputRing2.availableRead()
            let availableFrames = min(availableFrames1, availableFrames2)

            if !bufferedOutputPrimed {
                guard availableFrames1 >= prerollFrames, availableFrames2 >= prerollFrames else {
                    fillBufferedOutputScratchWithSilence(frames: frames)
                    return
                }
                bufferedOutputPrimed = true
            }
            let requestedFrames = UInt32(frames)
            guard availableFrames >= requestedFrames else {
                bufferedOutputPrimed = false
                fillBufferedOutputScratchWithSilence(frames: frames)
                recordDroppedFrames(requestedFrames - availableFrames)
                return
            }

            let receivedFrames1 = bufferedOutputRing1.read(into: outputScratch1, count: requestedFrames)
            var droppedFrames = requestedFrames - receivedFrames1
            if Int(receivedFrames1) < frames {
                outputScratch1.advanced(by: Int(receivedFrames1)).update(repeating: 0, count: frames - Int(receivedFrames1))
            }

            if configuration.channelCount == 2, let outputScratch2 {
                let receivedFrames2 = bufferedOutputRing2.read(into: outputScratch2, count: requestedFrames)
                droppedFrames = max(droppedFrames, requestedFrames - receivedFrames2)
                if Int(receivedFrames2) < frames {
                    outputScratch2.advanced(by: Int(receivedFrames2)).update(repeating: 0, count: frames - Int(receivedFrames2))
                }
            }

            if droppedFrames > 0 {
                bufferedOutputPrimed = false
                recordDroppedFrames(droppedFrames)
            }
        }

        private func bufferedOutputPrerollFrames(stagingFrames: Int) -> UInt32 {
            let processingPrerollFrames = configuration.latencyClass == .broadcast
                ? processingFrames * broadcastPrerollMultiplier
                : processingFrames
            return UInt32(max(processingPrerollFrames, stagingFrames * 2))
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

            if plugins.isEmpty {
                outputScratch1.update(from: input1, count: frameCount)
                if configuration.channelCount == 2, let input2, let outputScratch2 {
                    outputScratch2.update(from: input2, count: frameCount)
                }
                renderSampleTime += Double(frameCount)
                return true
            }

            let originalInput2 = configuration.channelCount == 2 ? input2 : nil
            var source1 = input1
            var source2 = originalInput2
            var destination1 = outputScratch1
            var destination2 = configuration.channelCount == 2 ? outputScratch2 : nil
            let bytes = UInt32(frameCount * MemoryLayout<Float>.size)

            for (index, plugin) in plugins.enumerated() {
                currentInputSource1 = source1
                currentInputSource2 = source2

                if let wetBufferList {
                    wetBufferList[0].mData = UnsafeMutableRawPointer(destination1)
                    wetBufferList[0].mDataByteSize = bytes
                    if configuration.channelCount == 2 {
                        wetBufferList[1].mData = UnsafeMutableRawPointer(destination2)
                        wetBufferList[1].mDataByteSize = bytes
                    }
                }

                var renderFlags: AudioUnitRenderActionFlags = []
                var timeStamp = AudioTimeStamp()
                timeStamp.mSampleTime = renderSampleTime
                timeStamp.mFlags = AudioTimeStampFlags(rawValue: 1 << 0)

                let status = AudioUnitRender(
                    plugin.unit,
                    &renderFlags,
                    &timeStamp,
                    0,
                    UInt32(frameCount),
                    wetBufferList!.unsafeMutablePointer
                )

                if status != noErr {
                    currentInputSource1 = nil
                    currentInputSource2 = nil
                    renderSampleTime += Double(frameCount)
                    recordDroppedFrames(UInt32(frameCount))
                    outputScratch1.update(from: input1, count: frameCount)
                    if configuration.channelCount == 2, let originalInput2, let outputScratch2 {
                        outputScratch2.update(from: originalInput2, count: frameCount)
                    }
                    return false
                }

                if index < plugins.count - 1 {
                    source1 = destination1
                    source2 = destination2
                    if source1 == outputScratch1 {
                        destination1 = intermediateScratch1 ?? outputScratch1
                        destination2 = intermediateScratch2 ?? outputScratch2
                    } else {
                        destination1 = outputScratch1
                        destination2 = outputScratch2
                    }
                }
            }

            currentInputSource1 = nil
            currentInputSource2 = nil
            if destination1 != outputScratch1 {
                outputScratch1.update(from: destination1, count: frameCount)
            }
            if configuration.channelCount == 2,
               let destination2,
               let outputScratch2,
               destination2 != outputScratch2 {
                outputScratch2.update(from: destination2, count: frameCount)
            }
            renderSampleTime += Double(frameCount)
            return true
        }

        private func recordDroppedFrames(_ frameCount: UInt32) {
            guard frameCount > 0 else { return }
            audioDropoutCounter.increment()
            droppedFrameCounter.add(UInt64(frameCount))
        }

        private func recordRenderDuration(_ nanoseconds: UInt64) {
            peakRenderDurationNanoseconds.storeMax(nanoseconds)
            totalRenderDurationNanoseconds.add(nanoseconds)
            renderPassCount.increment()
        }

        func serializedPluginStates() -> [UUID: Data] {
            var states: [UUID: Data] = [:]
            for insert in configuration.plugins {
                if let plugin = plugins.first(where: { $0.insert.id == insert.id }),
                   let data = serializedPluginState(for: plugin.unit) {
                    states[insert.id] = data
                } else if let data = insert.pluginStateData {
                    states[insert.id] = data
                }
            }
            return states
        }

        func applySerializedPluginStates() throws {
            for plugin in plugins {
                try applySerializedPluginState(plugin.insert.pluginStateData, to: plugin.unit)
            }
        }

        func applySerializedPluginStates(
            _ statesByInsertID: [UUID: Data]
        ) -> [UUID: String] {
            var failures: [UUID: String] = [:]

            for plugin in plugins {
                guard let stateData = statesByInsertID[plugin.insert.id] else {
                    continue
                }

                do {
                    try applySerializedPluginState(stateData, to: plugin.unit)
                } catch {
                    failures[plugin.insert.id] = plugin.plugin.name
                }
            }

            return failures
        }

        private func serializedPluginState(for unit: AudioUnit) -> Data? {
            var classInfo: Unmanaged<CFPropertyList>?
            var propertySize = UInt32(MemoryLayout<Unmanaged<CFPropertyList>?>.size)
            let status = AudioUnitGetProperty(
                unit,
                kAudioUnitProperty_ClassInfo,
                kAudioUnitScope_Global,
                0,
                &classInfo,
                &propertySize
            )

            guard status == noErr, let classInfo else {
                return nil
            }

            return try? PropertyListSerialization.data(
                fromPropertyList: classInfo.takeRetainedValue(),
                format: .binary,
                options: 0
            )
        }

        private func applySerializedPluginState(_ data: Data?, to unit: AudioUnit) throws {
            guard let data else { return }
            let propertyList = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
            guard propertyList is [String: Any] else {
                throw AudioHostError("Saved Audio Unit state is not a property-list dictionary.")
            }
            let cfPropertyList = propertyList as CFPropertyList
            var unmanagedPropertyList = Unmanaged.passUnretained(cfPropertyList)
            _ = try withExtendedLifetime(cfPropertyList) {
                try checkStatus(
                    AudioUnitSetProperty(
                        unit,
                        kAudioUnitProperty_ClassInfo,
                        kAudioUnitScope_Global,
                        0,
                        &unmanagedPropertyList,
                        UInt32(MemoryLayout<Unmanaged<CFPropertyList>>.size)
                    ),
                    "Failed to restore saved Audio Unit state"
                )
            }
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

        private static func latencyFrames(for unit: AudioUnit, sampleRate: Double) -> Int {
            guard sampleRate > 0 else { return 0 }
            var latencySeconds = Float64(0)
            var size = UInt32(MemoryLayout<Float64>.size)
            let status = AudioUnitGetProperty(
                unit,
                kAudioUnitProperty_Latency,
                kAudioUnitScope_Global,
                0,
                &latencySeconds,
                &size
            )
            guard status == noErr, latencySeconds > 0 else { return 0 }
            return Int(ceil(latencySeconds * sampleRate))
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

}
