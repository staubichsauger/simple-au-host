@preconcurrency import AudioToolbox
import AppKit
import CoreAudioKit
import CoreAudio
import Darwin
import Foundation

@objc(AUCocoaUIBase)
private protocol AUCocoaUIViewFactory: NSObjectProtocol {
    @objc(interfaceVersion)
    func interfaceVersion() -> UInt32

    @objc(uiViewForAudioUnit:withSize:)
    func uiViewForAudioUnit(_ audioUnit: AudioUnit, withSize size: NSSize) -> NSView?
}

private enum WavesTuneRealtimeParameterMap {
    static let scaleTypeParameterID: AudioUnitParameterID = 10
    static let scaleRootParameterID: AudioUnitParameterID = 11
    private static let speedPreferredNames = ["speed", "tune speed"]
    private static let noteTransitionPreferredNames = ["note transition", "note trans", "transition"]
    private static let speedParameterTokens = ["speed"]
    private static let noteTransitionParameterTokens = ["note", "transition"]

    static func matches(_ plugin: AudioUnitPluginInfo) -> Bool {
        plugin.name.localizedCaseInsensitiveContains("Waves Tune Real-Time")
    }

    static func resolveStrengthParameterIDs(for unit: AudioUnit) throws -> (
        speed: AudioUnitParameterID,
        noteTransition: AudioUnitParameterID
    ) {
        let parameterIDs = try availableParameterIDs(for: unit)

        guard let speedParameterID = try findParameterID(
            in: unit,
            parameterIDs: parameterIDs,
            preferredNames: speedPreferredNames,
            matchingAll: speedParameterTokens
        ) else {
            throw AudioHostError("Failed to locate the Waves Tune Speed parameter.")
        }

        guard let noteTransitionParameterID = try findParameterID(
            in: unit,
            parameterIDs: parameterIDs,
            preferredNames: noteTransitionPreferredNames,
            matchingAll: noteTransitionParameterTokens
        ) else {
            throw AudioHostError("Failed to locate the Waves Tune Note Transition parameter.")
        }

        return (speedParameterID, noteTransitionParameterID)
    }

    static func strengthValues(for unit: AudioUnit) throws -> (
        speed: Float,
        noteTransition: Float
    ) {
        let parameterIDs = try resolveStrengthParameterIDs(for: unit)
        return (
            try displayedParameterValue(for: parameterIDs.speed, in: unit),
            try displayedParameterValue(for: parameterIDs.noteTransition, in: unit)
        )
    }

    private static func availableParameterIDs(for unit: AudioUnit) throws -> [AudioUnitParameterID] {
        var propertySize: UInt32 = 0
        try checkStatus(
            AudioUnitGetPropertyInfo(
                unit,
                kAudioUnitProperty_ParameterList,
                kAudioUnitScope_Global,
                0,
                &propertySize,
                nil
            ),
            "Failed to inspect Audio Unit parameters"
        )

        let count = Int(propertySize) / MemoryLayout<AudioUnitParameterID>.size
        guard count > 0 else { return [] }

        var parameterIDs = Array(repeating: AudioUnitParameterID(0), count: count)
        try parameterIDs.withUnsafeMutableBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            try checkStatus(
                AudioUnitGetProperty(
                    unit,
                    kAudioUnitProperty_ParameterList,
                    kAudioUnitScope_Global,
                    0,
                    baseAddress,
                    &propertySize
                ),
                "Failed to load Audio Unit parameters"
            )
        }
        return parameterIDs
    }

    private static func findParameterID(
        in unit: AudioUnit,
        parameterIDs: [AudioUnitParameterID],
        preferredNames: [String],
        matchingAll tokens: [String]
    ) throws -> AudioUnitParameterID? {
        let normalizedTokens = tokens.map { $0.lowercased() }
        let normalizedPreferredNames = preferredNames.map(normalizeParameterName)
        var fallbackMatch: AudioUnitParameterID?

        for parameterID in parameterIDs {
            let parameterName = try parameterDisplayName(for: parameterID, in: unit)
            let normalizedName = normalizeParameterName(parameterName)

            if normalizedPreferredNames.contains(normalizedName) {
                return parameterID
            }

            if normalizedPreferredNames.contains(where: { preferredName in
                normalizedName.contains(preferredName)
            }) {
                fallbackMatch = fallbackMatch ?? parameterID
                continue
            }

            if normalizedTokens.allSatisfy(normalizedName.contains) {
                fallbackMatch = fallbackMatch ?? parameterID
            }
        }

        return fallbackMatch
    }

    private static func parameterDisplayName(
        for parameterID: AudioUnitParameterID,
        in unit: AudioUnit
    ) throws -> String {
        var parameterInfo = AudioUnitParameterInfo()
        var propertySize = UInt32(MemoryLayout<AudioUnitParameterInfo>.size)
        try checkStatus(
            AudioUnitGetProperty(
                unit,
                kAudioUnitProperty_ParameterInfo,
                kAudioUnitScope_Global,
                parameterID,
                &parameterInfo,
                &propertySize
            ),
            "Failed to read Audio Unit parameter info"
        )

        return withUnsafePointer(to: parameterInfo.name) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: parameterInfo.name)) { namePointer in
                String(cString: namePointer)
            }
        }
    }

    private static func displayedParameterValue(
        for parameterID: AudioUnitParameterID,
        in unit: AudioUnit
    ) throws -> Float {
        if let displayString = try parameterString(for: parameterID, in: unit),
           let displayValue = parseLeadingFloat(from: displayString) {
            return displayValue
        }

        var rawValue = AudioUnitParameterValue(0)
        try checkStatus(
            AudioUnitGetParameter(
                unit,
                parameterID,
                kAudioUnitScope_Global,
                0,
                &rawValue
            ),
            "Failed to read the Audio Unit parameter value"
        )
        return Float(rawValue)
    }

    static func parameterValue(
        for parameterID: AudioUnitParameterID,
        displayValue: Float,
        in unit: AudioUnit
    ) throws -> AudioUnitParameterValue {
        for candidate in parameterValueStringCandidates(for: displayValue) {
            if let resolvedValue = try parameterValue(
                for: parameterID,
                string: candidate,
                in: unit
            ) {
                return resolvedValue
            }
        }

        return AudioUnitParameterValue(displayValue)
    }

    private static func parameterString(
        for parameterID: AudioUnitParameterID,
        in unit: AudioUnit
    ) throws -> String? {
        var currentValue = AudioUnitParameterValue(0)
        try checkStatus(
            AudioUnitGetParameter(
                unit,
                parameterID,
                kAudioUnitScope_Global,
                0,
                &currentValue
            ),
            "Failed to read the Audio Unit parameter value"
        )

        return try withUnsafePointer(to: &currentValue) { valuePointer in
            var request = AudioUnitParameterStringFromValue(
                inParamID: parameterID,
                inValue: valuePointer,
                outString: nil
            )
            var propertySize = UInt32(MemoryLayout<AudioUnitParameterStringFromValue>.size)
            try checkStatus(
                AudioUnitGetProperty(
                    unit,
                    kAudioUnitProperty_ParameterStringFromValue,
                    kAudioUnitScope_Global,
                    0,
                    &request,
                    &propertySize
                ),
                "Failed to format the Audio Unit parameter value"
            )

            guard let outString = request.outString else { return nil }
            return outString.takeRetainedValue() as String
        }
    }

    private static func parameterValue(
        for parameterID: AudioUnitParameterID,
        string: String,
        in unit: AudioUnit
    ) throws -> AudioUnitParameterValue? {
        let cfString = string as CFString
        var request = AudioUnitParameterValueFromString(
            inParamID: parameterID,
            inString: Unmanaged.passUnretained(cfString),
            outValue: 0
        )
        var propertySize = UInt32(MemoryLayout<AudioUnitParameterValueFromString>.size)
        let status = AudioUnitGetProperty(
            unit,
            kAudioUnitProperty_ParameterValueFromString,
            kAudioUnitScope_Global,
            0,
            &request,
            &propertySize
        )

        guard status == noErr else { return nil }
        return request.outValue
    }

    private static func parameterValueStringCandidates(for displayValue: Float) -> [String] {
        let integerValue = Int(displayValue.rounded())
        let decimalString = String(format: "%.1f", displayValue)

        return [
            "\(integerValue) ms",
            "\(decimalString) ms",
            "\(integerValue)ms",
            "\(decimalString)ms",
            "\(integerValue)",
            decimalString
        ]
    }

    private static func parseLeadingFloat(from string: String) -> Float? {
        let scanner = Scanner(string: string)
        scanner.locale = Locale(identifier: "en_US_POSIX")
        return scanner.scanFloat()
    }

    private static func normalizeParameterName(_ name: String) -> String {
        name
            .lowercased()
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}

final class MultiTrackAudioHostController: @unchecked Sendable {
    @MainActor
    final class HostedPluginEditorSession {
        let viewController: NSViewController
        private let onInvalidate: () -> Void

        init(
            viewController: NSViewController,
            onInvalidate: @escaping () -> Void = {}
        ) {
            self.viewController = viewController
            self.onInvalidate = onInvalidate
        }

        func invalidate() {
            onInvalidate()
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
        @MainActor
        private final class NativeEditorRequest {
            typealias RequestViewControllerBlock = @convention(block) (NSViewController?) -> Void

            let id = UUID()
            private var continuation: CheckedContinuation<NSViewController?, Error>?
            private var timeoutTask: Task<Void, Never>?
            private(set) var callbackObject: AnyObject?

            init(continuation: CheckedContinuation<NSViewController?, Error>) {
                self.continuation = continuation
            }

            func installCallback(_ callback: @escaping RequestViewControllerBlock) {
                callbackObject = unsafeBitCast(callback, to: AnyObject.self)
            }

            func startTimeout(seconds: Double) {
                timeoutTask = Task { [id] in
                    let nanoseconds = UInt64(seconds * 1_000_000_000)
                    try? await Task.sleep(nanoseconds: nanoseconds)
                    await MainActor.run {
                        TrackRuntime.completeNativeEditorRequest(
                            id,
                            result: .failure(AudioHostError("Timed out while waiting for the plugin editor."))
                        )
                    }
                }
            }

            func complete(result: Result<NSViewController?, Error>) {
                guard let continuation else { return }
                self.continuation = nil
                timeoutTask?.cancel()
                timeoutTask = nil
                callbackObject = nil

                switch result {
                case .success(let viewController):
                    continuation.resume(returning: viewController)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }

        @MainActor private static var pendingNativeEditorRequests: [UUID: NativeEditorRequest] = [:]

        private struct PluginRuntime {
            let insert: MultiTrackTrackConfiguration.PluginInsert
            let plugin: AudioUnitPluginInfo
            let unit: AudioUnit
        }

        let configuration: MultiTrackTrackConfiguration
        let processingFrames: Int
        let sampleRate: Double

        private var plugins: [PluginRuntime] = []
        private var wetBufferList: UnsafeMutableAudioBufferListPointer?
        private var realtimeInputRing1 = SAHFloatRingBuffer()
        private var realtimeInputRing2 = SAHFloatRingBuffer()
        private var bufferedOutputRing1 = SAHFloatRingBuffer()
        private var bufferedOutputRing2 = SAHFloatRingBuffer()
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
        private var audioDropoutCounter = SAHAtomicCounter()
        private var droppedFrameCounter = SAHAtomicCounter()
        private var peakInputRingOccupancyFrames = SAHAtomicCounter()
        private var peakOutputRingOccupancyFrames = SAHAtomicCounter()
        private var peakRenderDurationNanoseconds = SAHAtomicCounter()
        private var totalRenderDurationNanoseconds = SAHAtomicCounter()
        private var renderPassCount = SAHAtomicCounter()

        init(
            configuration: MultiTrackTrackConfiguration,
            plugins: [(MultiTrackTrackConfiguration.PluginInsert, AudioUnitPluginInfo)],
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
            SAHAtomicCounterReset(&peakInputRingOccupancyFrames)
            SAHAtomicCounterReset(&peakOutputRingOccupancyFrames)
            SAHAtomicCounterReset(&peakRenderDurationNanoseconds)
            SAHAtomicCounterReset(&totalRenderDurationNanoseconds)
            SAHAtomicCounterReset(&renderPassCount)

            try prepareBuffers(hardwareBufferSize: hardwareBufferSize)

            var createdPlugins: [PluginRuntime] = []
            for (insert, plugin) in plugins {
                let unit = try Self.createEffectUnit(
                    plugin: plugin,
                    sampleRate: sampleRate,
                    channelCount: configuration.channelCount,
                    maximumFrames: processingFrames,
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
            intermediateScratch1 = UnsafeMutablePointer<Float>.allocate(capacity: processingFrames)

            if configuration.channelCount == 2 {
                inputScratch2 = UnsafeMutablePointer<Float>.allocate(capacity: processingFrames)
                outputScratch2 = UnsafeMutablePointer<Float>.allocate(capacity: processingFrames)
                intermediateScratch2 = UnsafeMutablePointer<Float>.allocate(capacity: processingFrames)
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
            renderSampleTime += Double(frameCount)
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

        func setWavesTuneRealtimeBypassed(_ isBypassed: Bool) throws -> Int {
            try applyToWavesTuneRealtimeUnits { plugin in
                var bypassedValue: UInt32 = isBypassed ? 1 : 0
                try checkStatus(
                    AudioUnitSetProperty(
                        plugin.unit,
                        kAudioUnitProperty_BypassEffect,
                        kAudioUnitScope_Global,
                        0,
                        &bypassedValue,
                        UInt32(MemoryLayout<UInt32>.size)
                    ),
                    "Failed to update Waves Tune bypass"
                )
            }
        }

        func applyWavesTuneRealtimeKeySelection(_ selection: WavesTuneKeySelection) throws -> Int {
            let normalizedSelection = selection.normalized
            return try applyToWavesTuneRealtimeUnits { plugin in
                try checkStatus(
                    AudioUnitSetParameter(
                        plugin.unit,
                        WavesTuneRealtimeParameterMap.scaleTypeParameterID,
                        kAudioUnitScope_Global,
                        0,
                        AudioUnitParameterValue(normalizedSelection.pluginScaleTypeValue),
                        0
                    ),
                    "Failed to update the Waves Tune scale type"
                )
                try checkStatus(
                    AudioUnitSetParameter(
                        plugin.unit,
                        WavesTuneRealtimeParameterMap.scaleRootParameterID,
                        kAudioUnitScope_Global,
                        0,
                        AudioUnitParameterValue(normalizedSelection.pluginScaleRootValue),
                        0
                    ),
                    "Failed to update the Waves Tune scale root"
                )
            }
        }

        func applyWavesTuneRealtimeStrength(_ strength: WavesTuneStrengthPreset) throws -> Int {
            guard let speed = strength.speed,
                  let noteTransition = strength.noteTransition else {
                return 0
            }

            return try applyToWavesTuneRealtimeUnits { plugin in
                let parameterIDs = try WavesTuneRealtimeParameterMap.resolveStrengthParameterIDs(for: plugin.unit)
                let speedValue = try WavesTuneRealtimeParameterMap.parameterValue(
                    for: parameterIDs.speed,
                    displayValue: speed,
                    in: plugin.unit
                )
                let noteTransitionValue = try WavesTuneRealtimeParameterMap.parameterValue(
                    for: parameterIDs.noteTransition,
                    displayValue: noteTransition,
                    in: plugin.unit
                )
                try checkStatus(
                    AudioUnitSetParameter(
                        plugin.unit,
                        parameterIDs.speed,
                        kAudioUnitScope_Global,
                        0,
                        speedValue,
                        0
                    ),
                    "Failed to update the Waves Tune Speed parameter"
                )
                try checkStatus(
                    AudioUnitSetParameter(
                        plugin.unit,
                        parameterIDs.noteTransition,
                        kAudioUnitScope_Global,
                        0,
                        noteTransitionValue,
                        0
                    ),
                    "Failed to update the Waves Tune Note Transition parameter"
                )
            }
        }

        func currentWavesTuneRealtimeStrengthPreset() throws -> WavesTuneStrengthPreset? {
            var resolvedPreset: WavesTuneStrengthPreset?

            for plugin in plugins where WavesTuneRealtimeParameterMap.matches(plugin.plugin) {
                let values = try WavesTuneRealtimeParameterMap.strengthValues(for: plugin.unit)
                let preset = WavesTuneStrengthPreset.matchingDisplayValues(
                    speed: values.speed,
                    noteTransition: values.noteTransition
                )

                if let resolvedPreset, resolvedPreset != preset {
                    return .custom
                }

                resolvedPreset = preset
            }

            return resolvedPreset
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

        private func applyToWavesTuneRealtimeUnits(
            _ body: (PluginRuntime) throws -> Void
        ) throws -> Int {
            var affectedUnits = 0

            for plugin in plugins where WavesTuneRealtimeParameterMap.matches(plugin.plugin) {
                try body(plugin)
                affectedUnits += 1
            }

            return affectedUnits
        }

        @MainActor
        func makePluginEditorSession(pluginID: UUID?) async throws -> HostedPluginEditorSession {
            let pluginRuntime: PluginRuntime
            if let pluginID {
                guard let resolvedPlugin = plugins.first(where: { $0.insert.id == pluginID }) else {
                    throw AudioHostError("This plugin insert is not loaded on the running track.")
                }
                pluginRuntime = resolvedPlugin
            } else if let firstPlugin = plugins.first {
                pluginRuntime = firstPlugin
            } else {
                throw AudioHostError("This track does not have a plugin loaded.")
            }
            let viewController = try await Self.requestPluginEditorViewController(for: pluginRuntime.unit)
            return HostedPluginEditorSession(viewController: viewController)
        }

        @MainActor
        private static func requestPluginEditorViewController(for effectUnit: AudioUnit) async throws -> NSViewController {
            if let nativeViewController = try await Self.requestNativeViewController(for: effectUnit) {
                return nativeViewController
            }
            if let cocoaViewController = try Self.makeCocoaPluginEditorViewController(for: effectUnit) {
                return cocoaViewController
            }
            throw AudioHostError("This plugin does not provide a host-openable editor on its live processing instance.")
        }

        @MainActor
        private static func requestNativeViewController(for effectUnit: AudioUnit) async throws -> NSViewController? {
            try await withCheckedThrowingContinuation { continuation in
                let request = NativeEditorRequest(continuation: continuation)
                pendingNativeEditorRequests[request.id] = request

                let requestID = request.id
                let callback: NativeEditorRequest.RequestViewControllerBlock = { viewController in
                    Task { @MainActor in
                        completeNativeEditorRequest(requestID, result: .success(viewController))
                    }
                }
                request.installCallback(callback)
                guard let callbackObject = request.callbackObject else {
                    completeNativeEditorRequest(
                        requestID,
                        result: .failure(AudioHostError("Failed to prepare the plugin editor callback."))
                    )
                    return
                }
                request.startTimeout(seconds: 5)
                var unmanagedCallbackObject = Unmanaged.passUnretained(callbackObject)

                let status = withExtendedLifetime(callbackObject) {
                    AudioUnitSetProperty(
                        effectUnit,
                        kAudioUnitProperty_RequestViewController,
                        kAudioUnitScope_Global,
                        0,
                        &unmanagedCallbackObject,
                        UInt32(MemoryLayout<Unmanaged<AnyObject>>.size)
                    )
                }

                if status != noErr {
                    if status == kAudioUnitErr_InvalidProperty {
                        completeNativeEditorRequest(requestID, result: .success(nil))
                    } else {
                        completeNativeEditorRequest(
                            requestID,
                            result: .failure(AudioHostError("Failed to request the plugin editor (\(describe(status: status)))."))
                        )
                    }
                }
            }
        }

        @MainActor
        private static func completeNativeEditorRequest(
            _ id: UUID,
            result: Result<NSViewController?, Error>
        ) {
            guard let request = pendingNativeEditorRequests.removeValue(forKey: id) else { return }
            request.complete(result: result)
        }

        @MainActor
        private static func makeCocoaPluginEditorViewController(for effectUnit: AudioUnit) throws -> NSViewController? {
            var dataSize: UInt32 = 0
            let infoStatus = AudioUnitGetPropertyInfo(
                effectUnit,
                kAudioUnitProperty_CocoaUI,
                kAudioUnitScope_Global,
                0,
                &dataSize,
                nil
            )

            guard infoStatus == noErr,
                  dataSize >= UInt32(MemoryLayout<UnsafeRawPointer?>.size + MemoryLayout<CFString?>.size) else {
                return nil
            }

            let rawBuffer = UnsafeMutableRawPointer.allocate(
                byteCount: Int(dataSize),
                alignment: MemoryLayout<AudioUnitCocoaViewInfo>.alignment
            )
            defer { rawBuffer.deallocate() }

            var propertySize = dataSize
            try checkStatus(
                AudioUnitGetProperty(
                    effectUnit,
                    kAudioUnitProperty_CocoaUI,
                    kAudioUnitScope_Global,
                    0,
                    rawBuffer,
                    &propertySize
                ),
                "Failed to load the plugin Cocoa editor"
            )

            let bundleURLPointer = rawBuffer.assumingMemoryBound(to: Optional<CFURL>.self)
            guard let bundleURL = bundleURLPointer.pointee as URL?,
                  let bundle = Bundle(url: bundleURL) else {
                throw AudioHostError("The plugin Cocoa editor bundle could not be loaded.")
            }

            do {
                try bundle.loadAndReturnError()
            } catch {
                throw AudioHostError("The plugin Cocoa editor bundle failed to load: \(error.localizedDescription)")
            }

            let classPointerOffset = MemoryLayout<UnsafeRawPointer?>.size
            let classCount = max(0, (Int(propertySize) - classPointerOffset) / MemoryLayout<CFString?>.size)
            let classNamesPointer = rawBuffer.advanced(by: classPointerOffset).assumingMemoryBound(to: Optional<CFString>.self)
            var attemptedClassNames: [String] = []

            for index in 0..<classCount {
                guard let className = classNamesPointer.advanced(by: index).pointee as String? else {
                    continue
                }
                attemptedClassNames.append(className)
                if let viewController = makeCocoaPluginEditorViewController(
                    bundle: bundle,
                    className: className,
                    effectUnit: effectUnit
                ) {
                    return viewController
                }
            }

            if let principalClassName = bundle.principalClass.map(NSStringFromClass),
               !attemptedClassNames.contains(principalClassName),
               let viewController = makeCocoaPluginEditorViewController(
                   bundle: bundle,
                   className: principalClassName,
                   effectUnit: effectUnit
               ) {
                return viewController
            }

            let attemptedDescription = attemptedClassNames.isEmpty ? "none" : attemptedClassNames.joined(separator: ", ")
            let principalDescription = bundle.principalClass.map(NSStringFromClass) ?? "none"
            throw AudioHostError(
                "The plugin advertises a Cocoa editor bundle, but no view factory could be created. " +
                "Classes tried: \(attemptedDescription). Principal class: \(principalDescription)."
            )
        }

        @MainActor
        private static func makeCocoaPluginEditorViewController(
            bundle: Bundle,
            className: String,
            effectUnit: AudioUnit
        ) -> NSViewController? {
            guard let factoryType = (bundle.classNamed(className) ?? NSClassFromString(className)) as? NSObject.Type,
                  let factory = factoryType.init() as? AUCocoaUIViewFactory,
                  let view = factory.uiViewForAudioUnit(effectUnit, withSize: NSSize(width: 720, height: 540)) else {
                return nil
            }

            view.translatesAutoresizingMaskIntoConstraints = true
            view.autoresizingMask = NSView.AutoresizingMask(arrayLiteral: .width, .height)
            let viewController = NSViewController()
            viewController.view = view
            return viewController
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
            workerThread.qualityOfService = latencyClass == .broadcast ? .utility : .userInteractive
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
            promoteCurrentThreadToAudioWorkerQoS(latencyClass == .broadcast ? QOS_CLASS_USER_INITIATED : QOS_CLASS_USER_INTERACTIVE)
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

                switch processReadiness(frameCount: frames) {
                case .ready:
                    break
                case .waitingForInput:
                    wakeup.wait()
                    windowWakeups += 1
                    updateTimingWindow(
                        now: currentUptimeNanoseconds(),
                        windowStart: &windowStart,
                        windowWakeups: &windowWakeups,
                        windowActiveNanoseconds: &windowActive
                    )
                    continue
                case .waitingForOutputSpace:
                    sched_yield()
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

        private enum ProcessReadiness {
            case ready
            case waitingForInput
            case waitingForOutputSpace
        }

        private func processReadiness(frameCount: UInt32) -> ProcessReadiness {
            let hasInput = inputRings.indices.allSatisfy { index in
                SAHFloatRingBufferAvailableRead(&inputRings[index]) >= frameCount
            }
            guard hasInput else { return .waitingForInput }

            let hasOutputSpace = tracks.allSatisfy { $0.canAcceptBufferedInput(frames: processingFrames) }
            return hasOutputSpace ? .ready : .waitingForOutputSpace
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
    @MainActor private var pluginEditorSessions: [String: HostedPluginEditorSession] = [:]
    @MainActor private var pluginEditorWindows: [String: PluginEditorWindowController] = [:]

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

            let availablePlugins = try AudioHostController().availablePlugins()

            trackRuntimes = try configuration.tracks.map { track in
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

    func pluginStateSnapshot() -> [UUID: [UUID: Data]] {
        Dictionary(uniqueKeysWithValues: trackRuntimes.compactMap { runtime in
            let states = runtime.serializedPluginStates()
            return states.isEmpty ? nil : (runtime.configuration.id, states)
        })
    }

    func applyPluginStates(
        for trackID: UUID,
        statesByInsertID: [UUID: Data]
    ) throws -> [UUID: String] {
        guard let runtime = trackRuntimes.first(where: { $0.configuration.id == trackID }) else {
            throw AudioHostError("This track is not loaded on the running engine.")
        }
        return runtime.applySerializedPluginStates(statesByInsertID)
    }

    func setWavesTuneRealtimeBypassed(_ isBypassed: Bool) throws -> Int {
        guard configuration != nil else {
            throw AudioHostError("Start the engine before changing Waves Tune bypass.")
        }

        return try trackRuntimes.reduce(into: 0) { count, runtime in
            count += try runtime.setWavesTuneRealtimeBypassed(isBypassed)
        }
    }

    func applyWavesTuneRealtimeKeySelection(_ selection: WavesTuneKeySelection) throws -> Int {
        guard configuration != nil else {
            throw AudioHostError("Start the engine before applying Waves Tune settings.")
        }

        let normalizedSelection = selection.normalized
        return try trackRuntimes.reduce(into: 0) { count, runtime in
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

        guard let runtime = trackRuntimes.first(where: { $0.configuration.id == trackID }) else {
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

        guard let runtime = trackRuntimes.first(where: { $0.configuration.id == trackID }) else {
            throw AudioHostError("This track is not loaded on the running engine.")
        }

        return try runtime.currentWavesTuneRealtimeStrengthPreset()
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
    func openPluginEditor(for trackID: UUID, pluginID: UUID? = nil) async throws {
        guard let runtime = trackRuntimes.first(where: { $0.configuration.id == trackID }) else {
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
        guard let runtime = trackRuntimes.first(where: { $0.configuration.id == trackID }) else {
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
