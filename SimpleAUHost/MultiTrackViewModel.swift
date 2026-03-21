import AVFoundation
import SwiftUI

@MainActor
final class MultiTrackViewModel: ObservableObject {
    @Published private(set) var inputDevices: [AudioDeviceInfo] = []
    @Published private(set) var outputDevices: [AudioDeviceInfo] = []
    @Published private(set) var plugins: [AudioUnitPluginInfo] = []
    @Published var selectedInputDeviceID: AudioDeviceID?
    @Published var selectedOutputDeviceID: AudioDeviceID?
    @Published var selectedBufferSize: Int = 128
    @Published var customBufferSizeText = "128"
    @Published var bufferedInternalBufferText = "512"
    @Published var broadcastInternalBufferText = "1024"
    @Published var tracks: [MultiTrackTrackConfiguration] = []
    @Published var isRunning = false
    @Published var isBusy = false
    @Published var statusMessage = "Ready."
    @Published private(set) var audioDropoutCount: UInt64 = 0
    @Published private(set) var droppedFrameCount: UInt64 = 0

    private let catalog = AudioHostController()
    private let controller = MultiTrackAudioHostController()
    private var latencyBufferSettings = MultiTrackLatencyBufferSettings(hardwareBufferSize: 128)
    private var audioDropoutMonitorTask: Task<Void, Never>?

    deinit {
        audioDropoutMonitorTask?.cancel()
        controller.stop()
    }

    var selectedInputDevice: AudioDeviceInfo? {
        guard let selectedInputDeviceID else { return nil }
        return inputDevices.first { $0.id == selectedInputDeviceID }
    }

    var selectedOutputDevice: AudioDeviceInfo? {
        guard let selectedOutputDeviceID else { return nil }
        return outputDevices.first { $0.id == selectedOutputDeviceID }
    }

    var commonBufferSizeRange: ClosedRange<Int>? {
        guard let input = selectedInputDevice, let output = selectedOutputDevice else { return nil }
        let lowerBound = max(input.bufferSizeRange.lowerBound, output.bufferSizeRange.lowerBound)
        let upperBound = min(input.bufferSizeRange.upperBound, output.bufferSizeRange.upperBound)
        guard lowerBound <= upperBound else { return nil }
        return lowerBound...upperBound
    }

    var availableBufferSizes: [Int] {
        guard let range = commonBufferSizeRange else { return [] }

        let candidates: Set<Int> = [
            range.lowerBound,
            range.upperBound,
            selectedInputDevice?.currentBufferSize ?? selectedBufferSize,
            selectedOutputDevice?.currentBufferSize ?? selectedBufferSize,
            16, 32, 64, 128, 256, 512, 1024, 2048, 4096
        ]

        return candidates
            .filter { range.contains($0) }
            .sorted()
    }

    var isSelectedBufferSizeValid: Bool {
        guard let range = commonBufferSizeRange else { return false }
        return range.contains(selectedBufferSize)
    }

    var bufferSizeHelpText: String {
        guard let range = commonBufferSizeRange else {
            return "No shared buffer size range is available for the selected devices."
        }
        return "Allowed range: \(range.lowerBound)-\(range.upperBound) frames"
    }

    var canStart: Bool {
        selectedInputDevice != nil &&
        selectedOutputDevice != nil &&
        isSelectedBufferSizeValid &&
        latencyBufferValidationMessages.isEmpty &&
        tracks.contains(where: \.isEnabled) &&
        invalidTrackMessages.isEmpty &&
        !isBusy
    }

    var invalidTrackMessages: [String] {
        tracks.compactMap { validateTrack($0) }
    }

    var latencyBufferValidationMessages: [String] {
        [
            validateLatencyBufferText(bufferedInternalBufferText, for: .buffered),
            validateLatencyBufferText(broadcastInternalBufferText, for: .broadcast)
        ]
        .compactMap { $0 }
    }

    func load() {
        do {
            let allDevices = try catalog.availableDevices()
            inputDevices = allDevices.filter { $0.inputChannelCount > 0 }
            outputDevices = allDevices.filter { $0.outputChannelCount > 0 }
            plugins = try catalog.availablePlugins()

            let defaultInputID = try catalog.defaultInputDeviceID()
            let defaultOutputID = try catalog.defaultOutputDeviceID()

            if selectedInputDeviceID == nil || !inputDevices.contains(where: { $0.id == selectedInputDeviceID }) {
                selectedInputDeviceID = inputDevices.first(where: { $0.id == defaultInputID })?.id ?? inputDevices.first?.id
            }
            if selectedOutputDeviceID == nil || !outputDevices.contains(where: { $0.id == selectedOutputDeviceID }) {
                selectedOutputDeviceID = outputDevices.first(where: { $0.id == defaultOutputID })?.id ?? outputDevices.first?.id
            }

            if tracks.isEmpty {
                addTrack(layout: .mono)
            }

            for index in tracks.indices {
                if let pluginID = tracks[index].pluginID,
                   !plugins.contains(where: { $0.id == pluginID }) {
                    tracks[index].pluginID = nil
                }
            }

            sanitizeTracks()
            sanitizeLatencyBufferSettings()
            if !isRunning {
                audioDropoutCount = 0
                droppedFrameCount = 0
            }
            statusMessage = isRunning ? "Running." : "Ready."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func handleDeviceSelectionChange() {
        sanitizeTracks()
    }

    func addMonoTrack() {
        addTrack(layout: .mono)
    }

    func addStereoTrack() {
        addTrack(layout: .stereo)
    }

    func removeTrack(id: UUID) {
        tracks.removeAll { $0.id == id }
        if tracks.isEmpty {
            addTrack(layout: .mono)
        }
    }

    func sanitizeTrack(id: UUID) {
        guard let index = tracks.firstIndex(where: { $0.id == id }) else { return }
        tracks[index] = sanitizedTrack(tracks[index])
    }

    func availableInputStartChannels(for track: MultiTrackTrackConfiguration) -> [Int] {
        guard let selectedInputDevice else { return [] }
        let maxStart = max(1, selectedInputDevice.inputChannelCount - track.channelCount + 1)
        return Array(1...maxStart)
    }

    func availableOutputStartChannels(for track: MultiTrackTrackConfiguration) -> [Int] {
        guard let selectedOutputDevice else { return [] }
        let maxStart = max(1, selectedOutputDevice.outputChannelCount - track.channelCount + 1)
        return Array(1...maxStart)
    }

    func internalBufferDescription(for track: MultiTrackTrackConfiguration) -> String {
        let internalFrames = latencyBufferSettings.internalFrames(
            for: track.latencyClass,
            hardwareBufferSize: selectedBufferSize
        )
        return "\(track.latencyClass.title): \(internalFrames) internal frames"
    }

    func applyCustomBufferSize() {
        let trimmed = customBufferSizeText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(trimmed) else {
            statusMessage = "Enter a numeric buffer size."
            customBufferSizeText = String(selectedBufferSize)
            return
        }

        guard let range = commonBufferSizeRange else {
            statusMessage = "No shared buffer size range is available for the selected devices."
            customBufferSizeText = String(selectedBufferSize)
            return
        }

        guard range.contains(value) else {
            statusMessage = "Buffer size must be within \(range.lowerBound)-\(range.upperBound) frames."
            customBufferSizeText = String(selectedBufferSize)
            return
        }

        selectedBufferSize = value
        customBufferSizeText = String(value)
        sanitizeLatencyBufferSettings()
        statusMessage = "Ready."
    }

    func applyBufferedInternalBufferSize() {
        applyLatencyBufferText(bufferedInternalBufferText, for: .buffered)
    }

    func applyBroadcastInternalBufferSize() {
        applyLatencyBufferText(broadcastInternalBufferText, for: .broadcast)
    }

    func toggleStartStop() {
        if isRunning {
            audioDropoutMonitorTask?.cancel()
            audioDropoutMonitorTask = nil
            audioDropoutCount = controller.audioDropoutCount()
            droppedFrameCount = controller.droppedFrameCount()
            controller.stop()
            isRunning = false
            statusMessage = "Stopped."
            return
        }

        guard canStart else {
            statusMessage = invalidTrackMessages.first ?? "Please complete the device and track configuration."
            return
        }

        isBusy = true
        statusMessage = "Requesting microphone access..."

        Task { [weak self] in
            guard let self else { return }

            let granted = await self.requestMicrophoneAccessIfNeeded()
            guard granted else {
                self.isBusy = false
                self.statusMessage = "Microphone access was not granted."
                return
            }

            do {
                let configuration = try self.makeConfiguration()
                try self.controller.start(configuration: configuration)
                self.isRunning = true
                self.audioDropoutCount = self.controller.audioDropoutCount()
                self.droppedFrameCount = self.controller.droppedFrameCount()
                self.startAudioDropoutMonitoring()
                self.statusMessage = "Running."
            } catch {
                self.audioDropoutMonitorTask?.cancel()
                self.audioDropoutMonitorTask = nil
                self.audioDropoutCount = self.controller.audioDropoutCount()
                self.droppedFrameCount = self.controller.droppedFrameCount()
                self.controller.stop()
                self.isRunning = false
                self.statusMessage = error.localizedDescription
            }

            self.isBusy = false
        }
    }

    private func addTrack(layout: TrackChannelLayout) {
        let trackNumber = tracks.count + 1
        tracks.append(
            MultiTrackTrackConfiguration(
                name: layout == .mono ? "Track \(trackNumber)" : "Stereo \(trackNumber)",
                layout: layout
            )
        )
        sanitizeTracks()
    }

    private func sanitizeTracks() {
        for index in tracks.indices {
            tracks[index] = sanitizedTrack(tracks[index])
        }
        if let firstBuffer = availableBufferSizes.first, !isSelectedBufferSizeValid {
            selectedBufferSize = firstBuffer
        }
        customBufferSizeText = String(selectedBufferSize)
    }

    private func sanitizeLatencyBufferSettings() {
        latencyBufferSettings.bufferedFrames = normalizedInternalBufferSize(latencyBufferSettings.bufferedFrames)
        latencyBufferSettings.broadcastFrames = normalizedInternalBufferSize(latencyBufferSettings.broadcastFrames)
        bufferedInternalBufferText = String(latencyBufferSettings.bufferedFrames)
        broadcastInternalBufferText = String(latencyBufferSettings.broadcastFrames)
    }

    private func normalizedInternalBufferSize(_ value: Int) -> Int {
        let minimum = max(1, selectedBufferSize)
        let maximum = 16_384
        let clamped = min(max(value, minimum), maximum)
        let remainder = clamped % minimum
        if remainder == 0 {
            return clamped
        }
        return min(clamped + (minimum - remainder), maximum)
    }

    private func validateLatencyBufferText(
        _ text: String,
        for latencyClass: TrackLatencyClass
    ) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(trimmed) else {
            return "\(latencyClass.title) internal buffer must be numeric."
        }

        guard value >= selectedBufferSize else {
            return "\(latencyClass.title) internal buffer must be at least the hardware buffer size."
        }

        guard value <= 16_384 else {
            return "\(latencyClass.title) internal buffer must not exceed 16384 frames."
        }

        guard value % selectedBufferSize == 0 else {
            return "\(latencyClass.title) internal buffer must be a whole multiple of the hardware buffer size."
        }

        return nil
    }

    private func applyLatencyBufferText(
        _ text: String,
        for latencyClass: TrackLatencyClass
    ) {
        if let error = validateLatencyBufferText(text, for: latencyClass) {
            statusMessage = error
            switch latencyClass {
            case .realtime:
                break
            case .buffered:
                bufferedInternalBufferText = String(latencyBufferSettings.bufferedFrames)
            case .broadcast:
                broadcastInternalBufferText = String(latencyBufferSettings.broadcastFrames)
            }
            return
        }

        let value = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? selectedBufferSize
        switch latencyClass {
        case .realtime:
            break
        case .buffered:
            latencyBufferSettings.bufferedFrames = value
            bufferedInternalBufferText = String(value)
        case .broadcast:
            latencyBufferSettings.broadcastFrames = value
            broadcastInternalBufferText = String(value)
        }
        statusMessage = "Ready."
    }

    private func sanitizedTrack(_ track: MultiTrackTrackConfiguration) -> MultiTrackTrackConfiguration {
        var track = track
        if let inputDevice = selectedInputDevice {
            let maxStart = max(1, inputDevice.inputChannelCount - track.channelCount + 1)
            track.inputStartChannel = min(max(1, track.inputStartChannel), maxStart)
        } else {
            track.inputStartChannel = 1
        }

        if let outputDevice = selectedOutputDevice {
            let maxStart = max(1, outputDevice.outputChannelCount - track.channelCount + 1)
            track.outputStartChannel = min(max(1, track.outputStartChannel), maxStart)
        } else {
            track.outputStartChannel = 1
        }

        return track
    }

    private func validateTrack(_ track: MultiTrackTrackConfiguration) -> String? {
        guard track.isEnabled else { return nil }
        guard let inputDevice = selectedInputDevice, let outputDevice = selectedOutputDevice else {
            return "Select both devices before starting multi track mode."
        }

        guard !track.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Every enabled track needs a name."
        }

        let requiredInputChannels = track.inputStartChannel + track.channelCount - 1
        guard requiredInputChannels <= inputDevice.inputChannelCount else {
            return "\(track.name) exceeds the selected input interface channel count."
        }

        let requiredOutputChannels = track.outputStartChannel + track.channelCount - 1
        guard requiredOutputChannels <= outputDevice.outputChannelCount else {
            return "\(track.name) exceeds the selected output interface channel count."
        }

        return nil
    }

    private func makeConfiguration() throws -> MultiTrackHostConfiguration {
        guard
            let inputDevice = selectedInputDevice,
            let outputDevice = selectedOutputDevice
        else {
            throw AudioHostError("Select both an input and an output interface before starting.")
        }

        let sanitizedTracks = tracks
            .map(sanitizedTrack)
            .filter(\.isEnabled)

        guard !sanitizedTracks.isEmpty else {
            throw AudioHostError("Enable at least one track before starting.")
        }
        if let firstLatencyError = latencyBufferValidationMessages.first {
            throw AudioHostError(firstLatencyError)
        }

        if let firstError = sanitizedTracks.compactMap(validateTrack).first {
            throw AudioHostError(firstError)
        }

        return MultiTrackHostConfiguration(
            inputDevice: inputDevice,
            outputDevice: outputDevice,
            bufferSize: selectedBufferSize,
            latencyBufferSettings: latencyBufferSettings,
            tracks: sanitizedTracks
        )
    }


    func resetDropoutCounters() {
        controller.resetDropoutCounters()
        audioDropoutCount = controller.audioDropoutCount()
        droppedFrameCount = controller.droppedFrameCount()
    }
    private func requestMicrophoneAccessIfNeeded() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        default:
            return false
        }
    }

    private func startAudioDropoutMonitoring() {
        audioDropoutMonitorTask?.cancel()
        audioDropoutMonitorTask = nil
        audioDropoutMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if let runtimeStatus = self.controller.runtimeStatusMessage() {
                    self.audioDropoutCount = self.controller.audioDropoutCount()
                    self.droppedFrameCount = self.controller.droppedFrameCount()
                    self.controller.stop()
                    self.isRunning = false
                    self.statusMessage = runtimeStatus
                    return
                }
                self.audioDropoutCount = self.controller.audioDropoutCount()
                self.droppedFrameCount = self.controller.droppedFrameCount()
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }
}
