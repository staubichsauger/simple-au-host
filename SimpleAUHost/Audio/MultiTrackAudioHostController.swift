@preconcurrency import AudioToolbox
import AppKit
import CoreAudioKit
import CoreAudio
import Darwin
import Foundation

extension AUAudioUnit: @unchecked @retroactive Sendable {}

final class MultiTrackAudioHostController: @unchecked Sendable {
    @MainActor
    private final class PluginEditorSession {
        let audioUnit: AUAudioUnit
        let viewController: NSViewController
        let parameterObserverToken: AUParameterObserverToken?
        let stateSyncTimer: Timer?

        init(
            audioUnit: AUAudioUnit,
            viewController: NSViewController,
            parameterObserverToken: AUParameterObserverToken?,
            stateSyncTimer: Timer?
        ) {
            self.audioUnit = audioUnit
            self.viewController = viewController
            self.parameterObserverToken = parameterObserverToken
            self.stateSyncTimer = stateSyncTimer
        }

        func invalidate() {
            if let parameterTree = audioUnit.parameterTree, let parameterObserverToken {
                parameterTree.removeParameterObserver(parameterObserverToken)
            }
            stateSyncTimer?.invalidate()
        }
    }

    @MainActor
    private final class PluginEditorWindowController: NSWindowController, NSWindowDelegate {
        let trackID: UUID
        var onClose: (() -> Void)?

        init(trackID: UUID, title: String, contentViewController: NSViewController) {
            self.trackID = trackID
            let contentView = contentViewController.view
            let fittingSize = contentView.fittingSize
            let contentSize = NSSize(width: max(520, fittingSize.width), height: max(420, fittingSize.height))
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: contentSize),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = title
            window.center()
            window.contentViewController = contentViewController
            super.init(window: window)
            window.delegate = self
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            nil
        }

        func windowWillClose(_ notification: Notification) {
            onClose?()
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

        private let plugin: AudioUnitPluginInfo?
        private var effectUnit: AudioUnit?
        private var wetBufferList: UnsafeMutableAudioBufferListPointer?
        private var realtimeInputRing1 = SAHFloatRingBuffer()
        private var realtimeInputRing2 = SAHFloatRingBuffer()
        private var bufferedOutputRing1 = SAHFloatRingBuffer()
        private var bufferedOutputRing2 = SAHFloatRingBuffer()
        private var inputScratch1: UnsafeMutablePointer<Float>?
        private var inputScratch2: UnsafeMutablePointer<Float>?
        private var outputScratch1: UnsafeMutablePointer<Float>?
        private var outputScratch2: UnsafeMutablePointer<Float>?
        private var currentInputSource1: UnsafeMutablePointer<Float>?
        private var currentInputSource2: UnsafeMutablePointer<Float>?
        private var bufferedOutputPrimed = false
        private var renderSampleTime: Double = 0
        private var audioDropoutCounter = SAHAtomicCounter()
        private var droppedFrameCounter = SAHAtomicCounter()
        private var peakInputRingOccupancyFrames = SAHAtomicCounter()
        private var peakOutputRingOccupancyFrames = SAHAtomicCounter()
        private var peakRenderDurationNanoseconds = SAHAtomicCounter()
        private var totalRenderDurationNanoseconds = SAHAtomicCounter()
        private var renderPassCount = SAHAtomicCounter()

        init(
            configuration: MultiTrackTrackConfiguration,
            plugin: AudioUnitPluginInfo?,
            sampleRate: Double,
            hardwareBufferSize: Int,
            internalBufferFrames: Int
        ) throws {
            self.configuration = configuration
            self.plugin = plugin
            self.sampleRate = sampleRate
            self.processingFrames = configuration.latencyClass == .realtime
                ? hardwareBufferSize
                : max(hardwareBufferSize, internalBufferFrames)
            SAHAtomicCounterReset(&audioDropoutCounter)
            SAHAtomicCounterReset(&droppedFrameCounter)
            SAHAtomicCounterReset(&peakInputRingOccupancyFrames)
            SAHAtomicCounterReset(&peakOutputRingOccupancyFrames)
            SAHAtomicCounterReset(&peakRenderDurationNanoseconds)
            SAHAtomicCounterReset(&totalRenderDurationNanoseconds)
            SAHAtomicCounterReset(&renderPassCount)

            try prepareBuffers(hardwareBufferSize: hardwareBufferSize)

            if let plugin {
                effectUnit = try Self.createEffectUnit(
                    plugin: plugin,
                    sampleRate: sampleRate,
                    channelCount: configuration.channelCount,
                    maximumFrames: processingFrames,
                    owner: self
                )
                try applySerializedPluginState(configuration.pluginStateData)
            }
        }

        deinit {
            if let effectUnit {
                AudioUnitUninitialize(effectUnit)
                AudioComponentInstanceDispose(effectUnit)
            }
            wetBufferList?.unsafeMutablePointer.deallocate()
            inputScratch1?.deallocate()
            inputScratch2?.deallocate()
            outputScratch1?.deallocate()
            outputScratch2?.deallocate()
            SAHFloatRingBufferDeinit(&realtimeInputRing1)
            SAHFloatRingBufferDeinit(&realtimeInputRing2)
            SAHFloatRingBufferDeinit(&bufferedOutputRing1)
            SAHFloatRingBufferDeinit(&bufferedOutputRing2)
        }

        func audioDropoutCount() -> UInt64 {
            SAHAtomicCounterLoad(&audioDropoutCounter)
        }

        func droppedFrameCount() -> UInt64 {
            SAHAtomicCounterLoad(&droppedFrameCounter)
        }

        func peakInputRingOccupancy() -> UInt64 {
            SAHAtomicCounterLoad(&peakInputRingOccupancyFrames)
        }

        func peakOutputRingOccupancy() -> UInt64 {
            SAHAtomicCounterLoad(&peakOutputRingOccupancyFrames)
        }

        func peakRenderDurationMicros() -> UInt64 {
            SAHAtomicCounterLoad(&peakRenderDurationNanoseconds) / 1_000
        }

        func averageRenderDurationMicros() -> UInt64 {
            let passes = SAHAtomicCounterLoad(&renderPassCount)
            guard passes > 0 else { return 0 }
            return (SAHAtomicCounterLoad(&totalRenderDurationNanoseconds) / passes) / 1_000
        }

        func hasBufferedOutput(frames: Int) -> Bool {
            guard configuration.latencyClass != .realtime else { return false }
            let requestedFrames = UInt32(frames)
            let available1 = SAHFloatRingBufferAvailableRead(&bufferedOutputRing1)
            let available2 = configuration.channelCount == 1 ? available1 : SAHFloatRingBufferAvailableRead(&bufferedOutputRing2)
            return available1 >= requestedFrames && available2 >= requestedFrames
        }

        func canAcceptBufferedInput(frames: Int) -> Bool {
            guard configuration.latencyClass != .realtime else { return false }
            let requestedFrames = UInt32(frames)
            let available1 = SAHFloatRingBufferAvailableWrite(&bufferedOutputRing1)
            let available2 = configuration.channelCount == 1 ? available1 : SAHFloatRingBufferAvailableWrite(&bufferedOutputRing2)
            return available1 >= requestedFrames && available2 >= requestedFrames
        }

        func resetDropoutCounters() {
            SAHAtomicCounterReset(&audioDropoutCounter)
            SAHAtomicCounterReset(&droppedFrameCounter)
            SAHAtomicCounterReset(&peakInputRingOccupancyFrames)
            SAHAtomicCounterReset(&peakOutputRingOccupancyFrames)
            SAHAtomicCounterReset(&peakRenderDurationNanoseconds)
            SAHAtomicCounterReset(&totalRenderDurationNanoseconds)
            SAHAtomicCounterReset(&renderPassCount)
        }

        var isRealtime: Bool {
            configuration.latencyClass == .realtime
        }

        var isBuffered: Bool {
            !isRealtime
        }

        var hasEffect: Bool {
            effectUnit != nil
        }

        var hasOpenablePluginEditor: Bool {
            plugin != nil
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
            let pluginWeight = hasEffect ? 4 : 1
            let latencyWeight = configuration.latencyClass == .broadcast ? 2 : 1
            return channelWeight * pluginWeight * latencyWeight
        }

        func enqueueRealtimeInput(
            source1: UnsafePointer<Float>,
            source2: UnsafePointer<Float>?,
            frameCount: UInt32
        ) {
            guard configuration.latencyClass == .realtime else { return }
            let writtenFrames1 = SAHFloatRingBufferWrite(&realtimeInputRing1, source1, frameCount)
            SAHAtomicCounterStoreMax(&peakInputRingOccupancyFrames, UInt64(SAHFloatRingBufferAvailableRead(&realtimeInputRing1)))
            var droppedFrames = frameCount - writtenFrames1
            if configuration.channelCount == 2, let source2 {
                let writtenFrames2 = SAHFloatRingBufferWrite(&realtimeInputRing2, source2, frameCount)
                SAHAtomicCounterStoreMax(&peakInputRingOccupancyFrames, UInt64(SAHFloatRingBufferAvailableRead(&realtimeInputRing2)))
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
            let writtenFrames1 = SAHFloatRingBufferWrite(&bufferedOutputRing1, outputScratch1, frames)
            SAHAtomicCounterStoreMax(&peakOutputRingOccupancyFrames, UInt64(SAHFloatRingBufferAvailableRead(&bufferedOutputRing1)))
            var droppedFrames = frames - writtenFrames1
            if configuration.channelCount == 2, let outputScratch2 {
                let writtenFrames2 = SAHFloatRingBufferWrite(&bufferedOutputRing2, outputScratch2, frames)
                SAHAtomicCounterStoreMax(&peakOutputRingOccupancyFrames, UInt64(SAHFloatRingBufferAvailableRead(&bufferedOutputRing2)))
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
                let inputRingCapacity = UInt32(max(hardwareBufferSize * 32, 4096))
                guard SAHFloatRingBufferInit(&realtimeInputRing1, inputRingCapacity) else {
                    throw AudioHostError("Failed to allocate multi-track realtime input buffer.")
                }
                if configuration.channelCount == 2 {
                    guard SAHFloatRingBufferInit(&realtimeInputRing2, inputRingCapacity) else {
                        throw AudioHostError("Failed to allocate stereo realtime input buffer.")
                    }
                }
            } else {
                guard SAHFloatRingBufferInit(&bufferedOutputRing1, ringCapacity) else {
                    throw AudioHostError("Failed to allocate multi-track output buffer.")
                }
                if configuration.channelCount == 2 {
                    guard SAHFloatRingBufferInit(&bufferedOutputRing2, ringCapacity) else {
                        throw AudioHostError("Failed to allocate stereo output buffer.")
                    }
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
            let receivedFrames1 = SAHFloatRingBufferRead(&realtimeInputRing1, inputScratch1, requestedFrames)
            var droppedFrames = requestedFrames - receivedFrames1
            if Int(receivedFrames1) < frames {
                inputScratch1.advanced(by: Int(receivedFrames1)).update(repeating: 0, count: frames - Int(receivedFrames1))
            }

            if configuration.channelCount == 2, let inputScratch2 {
                let receivedFrames2 = SAHFloatRingBufferRead(&realtimeInputRing2, inputScratch2, requestedFrames)
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
            let availableFrames1 = SAHFloatRingBufferAvailableRead(&bufferedOutputRing1)
            let availableFrames2 = configuration.channelCount == 1
                ? availableFrames1
                : SAHFloatRingBufferAvailableRead(&bufferedOutputRing2)

            if !bufferedOutputPrimed {
                guard availableFrames1 >= prerollFrames, availableFrames2 >= prerollFrames else {
                    fillBufferedOutputScratchWithSilence(frames: frames)
                    return
                }
                bufferedOutputPrimed = true
            }
            let requestedFrames = UInt32(frames)
            let receivedFrames1 = SAHFloatRingBufferRead(&bufferedOutputRing1, outputScratch1, requestedFrames)
            var droppedFrames = requestedFrames - receivedFrames1
            if Int(receivedFrames1) < frames {
                outputScratch1.advanced(by: Int(receivedFrames1)).update(repeating: 0, count: frames - Int(receivedFrames1))
            }

            if configuration.channelCount == 2, let outputScratch2 {
                let receivedFrames2 = SAHFloatRingBufferRead(&bufferedOutputRing2, outputScratch2, requestedFrames)
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

        private func recordRenderDuration(_ nanoseconds: UInt64) {
            SAHAtomicCounterStoreMax(&peakRenderDurationNanoseconds, nanoseconds)
            SAHAtomicCounterAdd(&totalRenderDurationNanoseconds, nanoseconds)
            SAHAtomicCounterIncrement(&renderPassCount)
        }

        func serializedPluginState() -> Data? {
            guard let effectUnit else { return pluginStatePlaceholderDataIfNeeded(nil) }

            var classInfo: CFPropertyList?
            var propertySize = UInt32(MemoryLayout<CFPropertyList?>.size)
            let status = AudioUnitGetProperty(
                effectUnit,
                kAudioUnitProperty_ClassInfo,
                kAudioUnitScope_Global,
                0,
                &classInfo,
                &propertySize
            )

            guard status == noErr, let classInfo else {
                return pluginStatePlaceholderDataIfNeeded(nil)
            }

            let data = try? PropertyListSerialization.data(
                fromPropertyList: classInfo,
                format: .binary,
                options: 0
            )
            return pluginStatePlaceholderDataIfNeeded(data)
        }

        func applySerializedPluginState(_ data: Data?) throws {
            guard let effectUnit, let data else { return }
            let propertyList = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
            var cfPropertyList = propertyList as CFPropertyList
            try checkStatus(
                AudioUnitSetProperty(
                    effectUnit,
                    kAudioUnitProperty_ClassInfo,
                    kAudioUnitScope_Global,
                    0,
                    &cfPropertyList,
                    UInt32(MemoryLayout<CFPropertyList>.size)
                ),
                "Failed to restore saved Audio Unit state"
            )
        }

        private func pluginStatePlaceholderDataIfNeeded(_ data: Data?) -> Data? {
            if effectUnit == nil {
                return configuration.pluginStateData
            }
            return data
        }

        func makePluginEditorSession(
            onParameterChange: @escaping @Sendable (AUParameterAddress, AUValue) -> Void,
            onPeriodicStateSync: @escaping @Sendable (AUAudioUnit) -> Void
        ) async throws -> PluginEditorSession {
            guard let plugin else {
                throw AudioHostError("This track does not have a plugin loaded.")
            }

            let editorAudioUnit = try await Self.instantiateEditorAudioUnit(plugin: plugin)
            try applyCurrentPluginState(to: editorAudioUnit)
            let parameterObserverToken = editorAudioUnit.parameterTree?.token(byAddingParameterObserver: { address, value in
                onParameterChange(address, value)
            })
            let viewController = try await Self.requestNativeViewControllerOrThrow(for: editorAudioUnit)
            return await MainActor.run {
                let stateSyncTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak editorAudioUnit] _ in
                    guard let editorAudioUnit else { return }
                    onPeriodicStateSync(editorAudioUnit)
                }
                return PluginEditorSession(
                    audioUnit: editorAudioUnit,
                    viewController: viewController,
                    parameterObserverToken: parameterObserverToken,
                    stateSyncTimer: stateSyncTimer
                )
            }
        }

        @MainActor
        private static func requestNativeViewControllerOrThrow(for editorAudioUnit: AUAudioUnit) async throws -> NSViewController {
            guard let viewController = await Self.requestNativeViewController(for: editorAudioUnit) else {
                throw AudioHostError("This plugin does not provide a native AUv3 editor.")
            }
            return viewController
        }

        func syncEditorStateToEffect(_ editorAudioUnit: AUAudioUnit) {
            guard let effectUnit else { return }
            guard let state = editorAudioUnit.fullStateForDocument ?? editorAudioUnit.fullState else { return }
            var propertyList = state as CFPropertyList
            _ = AudioUnitSetProperty(
                effectUnit,
                kAudioUnitProperty_ClassInfo,
                kAudioUnitScope_Global,
                0,
                &propertyList,
                UInt32(MemoryLayout<CFPropertyList>.size)
            )
        }

        func setEffectParameter(address: AUParameterAddress, value: AUValue) {
            guard let effectUnit else { return }
            AudioUnitSetParameter(effectUnit, AudioUnitParameterID(address), kAudioUnitScope_Global, 0, value, 0)
        }

        private func applyCurrentPluginState(to editorAudioUnit: AUAudioUnit) throws {
            guard let data = serializedPluginState(),
                  let propertyList = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
                return
            }
            editorAudioUnit.fullStateForDocument = propertyList
            editorAudioUnit.fullState = propertyList
        }

        @MainActor
        private static func instantiateEditorAudioUnit(plugin: AudioUnitPluginInfo) async throws -> AUAudioUnit {
            try await withCheckedThrowingContinuation { continuation in
                AUAudioUnit.instantiate(with: plugin.componentDescription, options: []) { audioUnit, error in
                    if let error {
                        continuation.resume(throwing: AudioHostError("Failed to open the plugin editor: \(error.localizedDescription)"))
                        return
                    }
                    guard let audioUnit else {
                        continuation.resume(throwing: AudioHostError("Failed to open the plugin editor."))
                        return
                    }
                    continuation.resume(returning: audioUnit)
                }
            }
        }

        @MainActor
        private static func requestNativeViewController(for audioUnit: AUAudioUnit) async -> NSViewController? {
            await withCheckedContinuation { continuation in
                audioUnit.requestViewController { viewController in
                    continuation.resume(returning: viewController)
                }
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

    private final class BufferedTrackWorkerShard: @unchecked Sendable {
        let id: Int
        let latencyClass: TrackLatencyClass
        let processingFrames: Int

        private let tracks: [TrackRuntime]
        private let inputChannelOffsets: [Int]
        private let channelIndexMap: [Int: Int]
        private let recordDroppedFrames: @Sendable (UInt32) -> Void
        private let runtimeStatusMessage: @Sendable () -> String?

        private var inputRings: [SAHFloatRingBuffer]
        private var stagedInputs: [UnsafeMutablePointer<Float>]
        private let stateLock = NSLock()
        private let wakeup = AudioWorkerWakeup()
        private let exitGroup = DispatchGroup()
        private var workerThread: Thread?
        private var shouldRun = false

        private var peakInputRingOccupancyFrames = SAHAtomicCounter()
        private var peakRenderDurationNanoseconds = SAHAtomicCounter()
        private var totalRenderDurationNanoseconds = SAHAtomicCounter()
        private var renderPassCount = SAHAtomicCounter()
        private var peakUtilizationPercent = SAHAtomicCounter()
        private var peakWakeupsPerSecond = SAHAtomicCounter()

        init(
            id: Int,
            latencyClass: TrackLatencyClass,
            tracks: [TrackRuntime],
            recordDroppedFrames: @escaping @Sendable (UInt32) -> Void,
            runtimeStatusMessage: @escaping @Sendable () -> String?
        ) throws {
            self.id = id
            self.latencyClass = latencyClass
            self.tracks = tracks
            self.recordDroppedFrames = recordDroppedFrames
            self.runtimeStatusMessage = runtimeStatusMessage
            self.processingFrames = tracks.first?.processingFrames ?? 0

            let orderedInputChannels = Set(tracks.flatMap(\.inputChannelOffsets)).sorted()
            self.inputChannelOffsets = orderedInputChannels
            self.channelIndexMap = Dictionary(uniqueKeysWithValues: orderedInputChannels.enumerated().map { ($1, $0) })
            self.inputRings = orderedInputChannels.map { _ in SAHFloatRingBuffer() }
            self.stagedInputs = []

            SAHAtomicCounterReset(&peakInputRingOccupancyFrames)
            SAHAtomicCounterReset(&peakRenderDurationNanoseconds)
            SAHAtomicCounterReset(&totalRenderDurationNanoseconds)
            SAHAtomicCounterReset(&renderPassCount)
            SAHAtomicCounterReset(&peakUtilizationPercent)
            SAHAtomicCounterReset(&peakWakeupsPerSecond)

            try prepareBuffers()
        }

        deinit {
            stopWorker()
            for pointer in stagedInputs {
                pointer.deallocate()
            }
            for index in inputRings.indices {
                SAHFloatRingBufferDeinit(&inputRings[index])
            }
        }

        var trackCount: Int {
            tracks.count
        }

        var inputRingCapacityFrames: Int {
            inputRings.reduce(0) { max($0, Int($1.capacity)) }
        }

        func peakInputRingOccupancy() -> UInt64 {
            SAHAtomicCounterLoad(&peakInputRingOccupancyFrames)
        }

        func peakRenderDurationMicros() -> UInt64 {
            SAHAtomicCounterLoad(&peakRenderDurationNanoseconds) / 1_000
        }

        func averageRenderDurationMicros() -> UInt64 {
            let passes = SAHAtomicCounterLoad(&renderPassCount)
            guard passes > 0 else { return 0 }
            return (SAHAtomicCounterLoad(&totalRenderDurationNanoseconds) / passes) / 1_000
        }

        func peakUtilization() -> UInt64 {
            SAHAtomicCounterLoad(&peakUtilizationPercent)
        }

        func peakWakeups() -> UInt64 {
            SAHAtomicCounterLoad(&peakWakeupsPerSecond)
        }

        func resetTelemetry() {
            SAHAtomicCounterReset(&peakInputRingOccupancyFrames)
            SAHAtomicCounterReset(&peakRenderDurationNanoseconds)
            SAHAtomicCounterReset(&totalRenderDurationNanoseconds)
            SAHAtomicCounterReset(&renderPassCount)
            SAHAtomicCounterReset(&peakUtilizationPercent)
            SAHAtomicCounterReset(&peakWakeupsPerSecond)
        }

        func enqueueInput(from captureBufferList: UnsafeMutableAudioBufferListPointer, frameCount: UInt32) {
            guard processingFrames > 0 else { return }
            var droppedFrames: UInt32 = 0
            for (ringIndex, channelOffset) in inputChannelOffsets.enumerated() {
                guard channelOffset < captureBufferList.count,
                      let source = captureBufferList[channelOffset].mData?.assumingMemoryBound(to: Float.self) else {
                    droppedFrames = max(droppedFrames, frameCount)
                    continue
                }
                let writtenFrames = SAHFloatRingBufferWrite(&inputRings[ringIndex], source, frameCount)
                SAHAtomicCounterStoreMax(&peakInputRingOccupancyFrames, UInt64(SAHFloatRingBufferAvailableRead(&inputRings[ringIndex])))
                droppedFrames = max(droppedFrames, frameCount - writtenFrames)
            }
            if droppedFrames > 0 {
                recordDroppedFrames(droppedFrames)
            }
        }

        func signalWorkAvailable() {
            wakeup.signal()
        }

        func startWorker(affinityTag: Int32?) {
            stateLock.lock()
            shouldRun = true
            stateLock.unlock()
            exitGroup.enter()

            let workerThread = Thread { [weak self] in
                defer {
                    self?.exitGroup.leave()
                }
                self?.workerLoop(affinityTag: affinityTag)
            }
            workerThread.name = "SimpleAUHost.TrackShard.\(latencyClass.rawValue).\(id)"
            workerThread.qualityOfService = latencyClass == .broadcast ? .utility : .userInitiated
            self.workerThread = workerThread
            workerThread.start()
        }

        func stopWorker() {
            stateLock.lock()
            shouldRun = false
            stateLock.unlock()

            workerThread?.cancel()
            wakeup.signal()
            if workerThread != nil {
                exitGroup.wait()
            }
            workerThread = nil
        }

        private func prepareBuffers() throws {
            let ringCapacity = UInt32(max(processingFrames * 32, 4096))
            for index in inputRings.indices {
                guard SAHFloatRingBufferInit(&inputRings[index], ringCapacity) else {
                    throw AudioHostError("Failed to allocate worker shard input buffer.")
                }
            }
            stagedInputs = inputChannelOffsets.map { _ in
                UnsafeMutablePointer<Float>.allocate(capacity: processingFrames)
            }
        }

        private func shouldContinue() -> Bool {
            stateLock.lock()
            defer { stateLock.unlock() }
            return shouldRun
        }

        private func workerLoop(affinityTag: Int32?) {
            guard processingFrames > 0 else { return }
            promoteCurrentThreadToAudioWorkerQoS()
            if let affinityTag {
                bestEffortSetCurrentThreadAffinity(tag: affinityTag)
            }

            let frames = UInt32(processingFrames)
            var windowStart = currentUptimeNanoseconds()
            var windowWakeups: UInt64 = 0
            var windowActive: UInt64 = 0

            while shouldContinue() && !Thread.current.isCancelled {
                if runtimeStatusMessage() != nil {
                    return
                }

                guard canProcessRound(frameCount: frames) else {
                    wakeup.wait()
                    windowWakeups += 1
                    updateTimingWindow(
                        now: currentUptimeNanoseconds(),
                        windowStart: &windowStart,
                        windowWakeups: &windowWakeups,
                        windowActiveNanoseconds: &windowActive
                    )
                    continue
                }

                let roundStart = currentUptimeNanoseconds()
                stageInputRound(frameCount: frames)
                for runtime in tracks {
                    guard let input1 = inputPointer(for: runtime.inputStartChannelOffset) else { continue }
                    let input2 = runtime.configuration.channelCount == 2
                        ? inputPointer(for: runtime.inputStartChannelOffset + 1)
                        : nil
                    runtime.renderBufferedOutput(input1: input1, input2: input2)
                }
                let roundDuration = currentUptimeNanoseconds() - roundStart
                SAHAtomicCounterStoreMax(&peakRenderDurationNanoseconds, roundDuration)
                SAHAtomicCounterAdd(&totalRenderDurationNanoseconds, roundDuration)
                SAHAtomicCounterIncrement(&renderPassCount)
                windowActive += roundDuration
                updateTimingWindow(
                    now: currentUptimeNanoseconds(),
                    windowStart: &windowStart,
                    windowWakeups: &windowWakeups,
                    windowActiveNanoseconds: &windowActive
                )
            }
        }

        private func canProcessRound(frameCount: UInt32) -> Bool {
            let hasInput = inputRings.indices.allSatisfy { index in
                SAHFloatRingBufferAvailableRead(&inputRings[index]) >= frameCount
            }
            let hasOutputSpace = tracks.allSatisfy { $0.canAcceptBufferedInput(frames: processingFrames) }
            return hasInput && hasOutputSpace
        }

        private func stageInputRound(frameCount: UInt32) {
            var droppedFrames: UInt32 = 0
            for index in inputRings.indices {
                let readFrames = SAHFloatRingBufferRead(&inputRings[index], stagedInputs[index], frameCount)
                if readFrames < frameCount {
                    droppedFrames = max(droppedFrames, frameCount - readFrames)
                    stagedInputs[index].advanced(by: Int(readFrames)).update(repeating: 0, count: processingFrames - Int(readFrames))
                }
            }
            if droppedFrames > 0 {
                recordDroppedFrames(droppedFrames)
            }
        }

        private func inputPointer(for channelOffset: Int) -> UnsafeMutablePointer<Float>? {
            guard let index = channelIndexMap[channelOffset], index < stagedInputs.count else {
                return nil
            }
            return stagedInputs[index]
        }

        private func updateTimingWindow(
            now: UInt64,
            windowStart: inout UInt64,
            windowWakeups: inout UInt64,
            windowActiveNanoseconds: inout UInt64
        ) {
            let oneSecond: UInt64 = 1_000_000_000
            guard now >= windowStart + oneSecond else { return }

            let elapsed = max(1, now - windowStart)
            let utilization = min(UInt64(100), (windowActiveNanoseconds * 100) / elapsed)
            SAHAtomicCounterStoreMax(&peakUtilizationPercent, utilization)
            SAHAtomicCounterStoreMax(&peakWakeupsPerSecond, windowWakeups)

            windowStart = now
            windowWakeups = 0
            windowActiveNanoseconds = 0
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
    private var broadcastTrackRuntimes: [TrackRuntime] = []
    private var realtimeTrackRuntimes: [TrackRuntime] = []
    private var bufferedWorkerShards: [BufferedTrackWorkerShard] = []
    private var captureBufferList: UnsafeMutableAudioBufferListPointer?
    private var captureChannelBuffers: [UnsafeMutablePointer<Float>] = []
    private var sharedStagedOutputBuffers: [SharedOutputChannelBuffer] = []
    private var stagedOutputScratchBuffers: [UnsafeMutablePointer<Float>] = []
    private var maxFramesPerSlice: UInt32 = 0
    private var callbackFrameCapacity: Int = 0
    private var audioDropoutCounter = SAHAtomicCounter()
    private var droppedFrameCounter = SAHAtomicCounter()
    private var peakInputCallbackFrames = SAHAtomicCounter()
    private var peakOutputCallbackFrames = SAHAtomicCounter()
    private var peakSharedInputRingOccupancyFrames = SAHAtomicCounter()
    private var peakStagedOutputRingOccupancyFrames = SAHAtomicCounter()
    private var nextExpectedInputSampleTime: Double?
    private var nextExpectedOutputSampleTime: Double?
    private let priorityController = AudioHostingPriorityController()
    private let runtimeStateLock = NSLock()
    private let deviceObserver = AudioHardwareChangeObserver()
    private let stagedOutputStateLock = NSLock()
    private let stagedOutputWakeup = AudioWorkerWakeup()
    private let stagedOutputExitGroup = DispatchGroup()
    private var runtimeStatus: String?
    private var stagedOutputThread: Thread?
    private var shouldRunStagedOutputWorker = false
    private var stagedOutputPrimed = false
    private var inputRingCapacityFrames = 0
    private var peakTrackOutputRingCapacityFrames = 0
    private var stagedOutputRingCapacityFrames = 0
    @MainActor private var pluginEditorSessions: [UUID: PluginEditorSession] = [:]
    @MainActor private var pluginEditorWindows: [UUID: PluginEditorWindowController] = [:]

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
            bufferedTrackRuntimes = trackRuntimes.filter { $0.configuration.latencyClass == .buffered }
            broadcastTrackRuntimes = trackRuntimes.filter { $0.configuration.latencyClass == .broadcast }
            realtimeTrackRuntimes = trackRuntimes.filter(\.isRealtime)
            peakTrackOutputRingCapacityFrames = trackRuntimes.reduce(0) { partialResult, runtime in
                max(partialResult, runtime.outputRingCapacityFrames)
            }
            try prepareBufferedWorkerShards()

            try createAndConfigureIOUnits(for: configuration)
            let actualInputMaxFrames = try actualMaximumFramesPerSlice(for: inputUnit)
            let actualOutputMaxFrames = try actualMaximumFramesPerSlice(for: outputUnit)
            callbackFrameCapacity = allocatedFrameCapacity(
                actualMaximumFrames: max(actualInputMaxFrames, actualOutputMaxFrames),
                nominalBufferSize: configuration.bufferSize
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
        let peakTrackInputOccupancy = realtimeTrackRuntimes.reduce(UInt64(0)) { partialResult, runtime in
            max(partialResult, runtime.peakInputRingOccupancy())
        }
        let peakShardInputOccupancy = bufferedWorkerShards.reduce(UInt64(0)) { partialResult, shard in
            max(partialResult, shard.peakInputRingOccupancy())
        }
        let peakTrackRenderDuration = trackRuntimes.reduce(UInt64(0)) { partialResult, runtime in
            max(partialResult, runtime.peakRenderDurationMicros())
        }
        let peakShardRenderDuration = bufferedWorkerShards.reduce(UInt64(0)) { partialResult, shard in
            max(partialResult, shard.peakRenderDurationMicros())
        }
        let averageTrackRenderDuration = averageMicros(
            totals: trackRuntimes.map { $0.averageRenderDurationMicros() },
            count: trackRuntimes.count
        )
        let averageShardRenderDuration = averageMicros(
            totals: bufferedWorkerShards.map { $0.averageRenderDurationMicros() },
            count: bufferedWorkerShards.count
        )
        let peakOutputOccupancy = max(peakTrackOutputOccupancy, SAHAtomicCounterLoad(&peakStagedOutputRingOccupancyFrames))
        return AudioEngineTelemetrySnapshot(
            peakInputCallbackFrames: SAHAtomicCounterLoad(&peakInputCallbackFrames),
            peakOutputCallbackFrames: SAHAtomicCounterLoad(&peakOutputCallbackFrames),
            peakEffectRenderFrames: 0,
            peakInputRingOccupancyFrames: max(peakTrackInputOccupancy, max(peakShardInputOccupancy, SAHAtomicCounterLoad(&peakSharedInputRingOccupancyFrames))),
            peakOutputRingOccupancyFrames: peakOutputOccupancy,
            inputRingCapacityFrames: inputRingCapacityFrames,
            outputRingCapacityFrames: max(peakTrackOutputRingCapacityFrames, stagedOutputRingCapacityFrames),
            peakTrackRenderDurationMicros: peakTrackRenderDuration,
            averageTrackRenderDurationMicros: averageTrackRenderDuration,
            peakShardRenderDurationMicros: peakShardRenderDuration,
            averageShardRenderDurationMicros: averageShardRenderDuration,
            peakShardUtilizationPercent: bufferedWorkerShards.reduce(0) { max($0, $1.peakUtilization()) },
            peakWorkerWakeupsPerSecond: bufferedWorkerShards.reduce(0) { max($0, $1.peakWakeups()) },
            workerShardCount: bufferedWorkerShards.count
        )
    }

    func pluginStateSnapshot() -> [UUID: Data] {
        Dictionary(uniqueKeysWithValues: trackRuntimes.compactMap { runtime in
            runtime.serializedPluginState().map { (runtime.configuration.id, $0) }
        })
    }

    func stop() {
        Task { @MainActor [weak self] in
            self?.closePluginEditorWindows()
        }
        stopBufferedWorkers()
        stopStagedOutputWorker()
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
        broadcastTrackRuntimes.removeAll()
        realtimeTrackRuntimes.removeAll()
        bufferedWorkerShards.removeAll()
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
        inputRingCapacityFrames = 0
        peakTrackOutputRingCapacityFrames = 0
        stagedOutputRingCapacityFrames = 0
        nextExpectedInputSampleTime = nil
        nextExpectedOutputSampleTime = nil
        clearRuntimeStatus()
        priorityController.deactivate()
    }

    @MainActor
    func openPluginEditor(for trackID: UUID) async throws {
        guard let runtime = trackRuntimes.first(where: { $0.configuration.id == trackID }) else {
            throw AudioHostError("Start the engine before opening a plugin editor.")
        }
        guard runtime.hasOpenablePluginEditor else {
            throw AudioHostError("This track does not have a plugin loaded.")
        }

        if let existingWindow = pluginEditorWindows[trackID] {
            existingWindow.showWindow(nil)
            existingWindow.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let editorSession = try await runtime.makePluginEditorSession(
            onParameterChange: { [weak runtime] address, value in
                runtime?.setEffectParameter(address: address, value: value)
            },
            onPeriodicStateSync: { [weak runtime] editorAudioUnit in
                runtime?.syncEditorStateToEffect(editorAudioUnit)
            }
        )
        let windowController = PluginEditorWindowController(
            trackID: trackID,
            title: runtime.configuration.name,
            contentViewController: editorSession.viewController
        )
        windowController.onClose = { [weak self] in
            Task { @MainActor in
                editorSession.invalidate()
                runtime.syncEditorStateToEffect(editorSession.audioUnit)
                self?.pluginEditorSessions.removeValue(forKey: trackID)
                self?.pluginEditorWindows.removeValue(forKey: trackID)
            }
        }
        pluginEditorSessions[trackID] = editorSession
        pluginEditorWindows[trackID] = windowController
        windowController.showWindow(nil)
        windowController.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func prepareCaptureBuffers(inputChannelCount: Int, ringCapacityFrames: Int) throws {
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
            let captureFrameCapacity = allocatedFrameCapacity(
                actualMaximumFrames: Int(maxFramesPerSlice),
                nominalBufferSize: configuration.bufferSize
            )
            let pointer = UnsafeMutablePointer<Float>.allocate(capacity: captureFrameCapacity)
            captureChannelBuffers.append(pointer)
            captureBufferList?[channelIndex].mNumberChannels = 1
            captureBufferList?[channelIndex].mDataByteSize = UInt32(captureFrameCapacity * MemoryLayout<Float>.size)
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

        guard let configuration else { return }
        let ringCapacity = UInt32(max(configuration.bufferSize * 32, 4096))

        for _ in 0..<outputChannelCount {
                let buffer = SharedOutputChannelBuffer()
            guard SAHFloatRingBufferInit(&buffer.ring, ringCapacity) else {
                throw AudioHostError("Failed to allocate staged output buffer.")
            }
            sharedStagedOutputBuffers.append(buffer)
            stagedOutputScratchBuffers.append(UnsafeMutablePointer<Float>.allocate(capacity: configuration.bufferSize))
            stagedOutputRingCapacityFrames = max(stagedOutputRingCapacityFrames, Int(buffer.ring.capacity))
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
        if runtimeStatusMessage() != nil {
            return noErr
        }
        SAHAtomicCounterStoreMax(&peakOutputCallbackFrames, UInt64(inNumberFrames))
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
}

private extension MultiTrackAudioHostController {
    func prepareBufferedWorkerShards() throws {
        stopBufferedWorkers()
        bufferedWorkerShards.removeAll()
        inputRingCapacityFrames = realtimeTrackRuntimes.reduce(0) { max($0, $1.outputRingCapacityFrames) }

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
        bufferedWorkerShards = bufferedShards + broadcastShards
        inputRingCapacityFrames = bufferedWorkerShards.reduce(inputRingCapacityFrames) { max($0, $1.inputRingCapacityFrames) }
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

    func stopBufferedWorkers() {
        for shard in bufferedWorkerShards {
            shard.stopWorker()
        }
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
        stagedOutputThread.qualityOfService = .userInitiated
        self.stagedOutputThread = stagedOutputThread
        stagedOutputThread.start()
    }

    func stopStagedOutputWorker() {
        stagedOutputStateLock.lock()
        shouldRunStagedOutputWorker = false
        stagedOutputStateLock.unlock()

        stagedOutputThread?.cancel()
        stagedOutputWakeup.signal()
        if stagedOutputThread != nil {
            stagedOutputExitGroup.wait()
        }
        stagedOutputThread = nil
    }

    func shouldStagedOutputWorkerContinue() -> Bool {
        stagedOutputStateLock.lock()
        defer { stagedOutputStateLock.unlock() }
        return shouldRunStagedOutputWorker
    }

    func stagedOutputWorkerLoop() {
        guard let configuration, !(bufferedTrackRuntimes.isEmpty && broadcastTrackRuntimes.isEmpty) else { return }
        promoteCurrentThreadToAudioWorkerQoS()
        let frames = configuration.bufferSize

        while shouldStagedOutputWorkerContinue() && !Thread.current.isCancelled {
            if runtimeStatusMessage() != nil {
                return
            }

            let hasRingSpace = sharedStagedOutputBuffers.allSatisfy {
                SAHFloatRingBufferAvailableWrite(&$0.ring) >= UInt32(frames)
            }
            let hasTrackOutput = (bufferedTrackRuntimes + broadcastTrackRuntimes).contains { runtime in
                runtime.hasBufferedOutput(frames: frames)
            }

            guard hasRingSpace, hasTrackOutput else {
                stagedOutputWakeup.wait()
                continue
            }

            for pointer in stagedOutputScratchBuffers {
                clearAudioBuffer(pointer, frameCount: frames)
            }

            for runtime in bufferedTrackRuntimes + broadcastTrackRuntimes {
                runtime.stageBufferedOutput(into: stagedOutputScratchBuffers, frames: frames)
            }

            for (index, buffer) in sharedStagedOutputBuffers.enumerated() {
                let writtenFrames = SAHFloatRingBufferWrite(&buffer.ring, stagedOutputScratchBuffers[index], UInt32(frames))
                SAHAtomicCounterStoreMax(&peakStagedOutputRingOccupancyFrames, UInt64(SAHFloatRingBufferAvailableRead(&buffer.ring)))
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
        let prerollFrames = UInt32(max(configuration?.bufferSize ?? frameCount, frameCount * 2))
        let minAvailable = sharedStagedOutputBuffers.reduce(UInt32.max) { partialResult, buffer in
            min(partialResult, SAHFloatRingBufferAvailableRead(&buffer.ring))
        }

        if !stagedOutputPrimed {
            guard minAvailable >= prerollFrames else {
                return
            }
            stagedOutputPrimed = true
        }

        var droppedFrames: UInt32 = 0
        for index in 0..<min(outputBuffers.count, sharedStagedOutputBuffers.count) {
            guard let destination = outputBuffers[index].mData?.assumingMemoryBound(to: Float.self) else {
                continue
            }
            let readFrames = SAHFloatRingBufferRead(&sharedStagedOutputBuffers[index].ring, destination, requestedFrames)
            SAHAtomicCounterStoreMax(&peakStagedOutputRingOccupancyFrames, UInt64(SAHFloatRingBufferAvailableRead(&sharedStagedOutputBuffers[index].ring)))
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

    func resetTelemetry() {
        SAHAtomicCounterReset(&peakInputCallbackFrames)
        SAHAtomicCounterReset(&peakOutputCallbackFrames)
        SAHAtomicCounterReset(&peakSharedInputRingOccupancyFrames)
        SAHAtomicCounterReset(&peakStagedOutputRingOccupancyFrames)
        for shard in bufferedWorkerShards {
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
        signalBufferedWorkers()
        stagedOutputWakeup.signal()
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

    func averageMicros(totals: [UInt64], count: Int) -> UInt64 {
        guard count > 0 else { return 0 }
        return totals.reduce(0, +) / UInt64(count)
    }

    @MainActor
    func closePluginEditorWindows() {
        for (trackID, windowController) in pluginEditorWindows {
            if let session = pluginEditorSessions[trackID],
               let runtime = trackRuntimes.first(where: { $0.configuration.id == trackID }) {
                session.invalidate()
                runtime.syncEditorStateToEffect(session.audioUnit)
            }
            windowController.close()
        }
        pluginEditorSessions.removeAll()
        pluginEditorWindows.removeAll()
    }
}

private func currentUptimeNanoseconds() -> UInt64 {
    DispatchTime.now().uptimeNanoseconds
}

private func estimatedPerformanceCoreCount() -> Int {
    for key in ["hw.perflevel0.physicalcpu", "hw.perflevel0.logicalcpu"] {
        if let value = sysctlInt(named: key), value > 0 {
            return value
        }
    }
    return ProcessInfo.processInfo.activeProcessorCount
}

private func sysctlInt(named name: String) -> Int? {
    var value: Int32 = 0
    var size = MemoryLayout<Int32>.size
    let result = name.withCString { pointer in
        sysctlbyname(pointer, &value, &size, nil, 0)
    }
    guard result == 0 else { return nil }
    return Int(value)
}

private func bestEffortSetCurrentThreadAffinity(tag: Int32) {
    var policy = thread_affinity_policy_data_t(affinity_tag: tag)
    withUnsafeMutablePointer(to: &policy) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: 1) { rebounded in
            _ = thread_policy_set(
                mach_thread_self(),
                thread_policy_flavor_t(THREAD_AFFINITY_POLICY),
                rebounded,
                1
            )
        }
    }
}
