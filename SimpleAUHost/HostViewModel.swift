import AVFoundation
import Combine
import SwiftUI

@MainActor
final class HostViewModel: ObservableObject {
    private struct PersistedSettings: Codable {
        let inputDeviceID: AudioDeviceID?
        let outputDeviceID: AudioDeviceID?
        let inputChannel: Int
        let outputChannel: Int
        let bufferSize: Int
        let pluginID: String?
        let threadedProcessingEnabled: Bool
        let threadedProcessingBufferSize: Int
    }

    private static let persistedSettingsKey = "HostViewModel.persistedSettings"
    @Published private(set) var inputDevices: [AudioDeviceInfo] = []
    @Published private(set) var outputDevices: [AudioDeviceInfo] = []
    @Published private(set) var plugins: [AudioUnitPluginInfo] = []
    @Published var selectedInputDeviceID: AudioDeviceID?
    @Published var selectedOutputDeviceID: AudioDeviceID?
    @Published var selectedInputChannel: Int = 1
    @Published var selectedOutputChannel: Int = 1
    @Published var selectedBufferSize: Int = DefaultBufferSizes.hardwareFrames
    @Published var customBufferSizeText = String(DefaultBufferSizes.hardwareFrames)
    @Published var selectedPluginID: String?
    @Published var threadedProcessingEnabled = false
    @Published var threadedProcessingBufferSizeText = String(DefaultBufferSizes.bufferedFrames)

    @Published var isRunning = false
    @Published var isBusy = false
    @Published var statusMessage = "Ready."
    @Published private(set) var audioDropoutCount: UInt64 = 0
    @Published private(set) var droppedFrameCount: UInt64 = 0
    @Published private(set) var telemetrySummary = "Callbacks in/out/effect: 0 / 0 / 0 frames"
    @Published private(set) var ringTelemetrySummary = "Peak ring occupancy in/out: 0 / 0 frames"

    private let controller = AudioHostController()
    private let userDefaults: UserDefaults
    private var audioDropoutMonitorTask: Task<Void, Never>?
    private var persistenceCancellables = Set<AnyCancellable>()

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        if let data = userDefaults.data(forKey: Self.persistedSettingsKey),
           let settings = try? JSONDecoder().decode(PersistedSettings.self, from: data) {
            selectedInputDeviceID = settings.inputDeviceID
            selectedOutputDeviceID = settings.outputDeviceID
            selectedInputChannel = settings.inputChannel
            selectedOutputChannel = settings.outputChannel
            selectedBufferSize = settings.bufferSize
            customBufferSizeText = String(settings.bufferSize)
            selectedPluginID = settings.pluginID
            threadedProcessingEnabled = settings.threadedProcessingEnabled
            threadedProcessingBufferSizeText = String(settings.threadedProcessingBufferSize)
        }

        setupPersistenceObservers()
    }

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

    var availableInputChannels: [Int] {
        guard let selectedInputDevice else { return [] }
        return Array(1...selectedInputDevice.inputChannelCount)
    }

    var availableOutputChannels: [Int] {
        guard let selectedOutputDevice else { return [] }
        return Array(1...selectedOutputDevice.outputChannelCount)
    }

    var availableBufferSizes: [Int] {
        guard let range = commonBufferSizeRange else { return [] }

        let commonCandidates: Set<Int> = [
            range.lowerBound,
            range.upperBound,
            selectedInputDevice?.currentBufferSize ?? selectedBufferSize,
            selectedOutputDevice?.currentBufferSize ?? selectedBufferSize,
            16, 32, 64, 128, 256, 512, 1024, 2048, 4096
        ]

        return commonCandidates
            .filter { range.contains($0) }
            .sorted()
    }

    var commonBufferSizeRange: ClosedRange<Int>? {
        guard let input = selectedInputDevice, let output = selectedOutputDevice else { return nil }

        let lowerBound = max(input.bufferSizeRange.lowerBound, output.bufferSizeRange.lowerBound)
        let upperBound = min(input.bufferSizeRange.upperBound, output.bufferSizeRange.upperBound)
        guard lowerBound <= upperBound else { return nil }

        return lowerBound...upperBound
    }

    var bufferSizeHelpText: String {
        guard let range = commonBufferSizeRange else {
            return "No shared buffer size range is available for the selected devices."
        }
        return "Allowed range: \(range.lowerBound)-\(range.upperBound) frames"
    }

    var isSelectedBufferSizeValid: Bool {
        guard let range = commonBufferSizeRange else { return false }
        return range.contains(selectedBufferSize)
    }

    var canStart: Bool {
        selectedInputDevice != nil &&
        selectedOutputDevice != nil &&
        availableInputChannels.contains(selectedInputChannel) &&
        availableOutputChannels.contains(selectedOutputChannel) &&
        isSelectedBufferSizeValid &&
        threadedProcessingValidationMessage == nil &&
        !isBusy
    }

    var statusColor: Color {
        if isRunning {
            return .green
        }
        if statusMessage.lowercased().contains("error") || statusMessage.lowercased().contains("failed") {
            return .red
        }
        return .secondary
    }

    var threadedProcessingValidationMessage: String? {
        guard threadedProcessingEnabled else { return nil }
        let trimmed = threadedProcessingBufferSizeText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(trimmed) else {
            return "Threaded plugin buffer must be numeric."
        }
        guard value >= selectedBufferSize else {
            return "Threaded plugin buffer must be at least the hardware buffer size."
        }
        guard value <= 16_384 else {
            return "Threaded plugin buffer must not exceed 16384 frames."
        }
        guard value % selectedBufferSize == 0 else {
            return "Threaded plugin buffer must be a whole multiple of the hardware buffer size."
        }
        return nil
    }

    var threadedProcessingHelpText: String {
        if selectedPluginID == nil {
            return "This only affects the selected plugin. In bypass, audio stays on the direct path."
        }
        return "Runs the plugin on a dedicated worker thread with added latency, similar to buffered mode."
    }

    func load() {
        do {
            let allDevices = try controller.availableDevices()
            inputDevices = allDevices.filter { $0.inputChannelCount > 0 }
            outputDevices = allDevices.filter { $0.outputChannelCount > 0 }
            plugins = try controller.availablePlugins()

            let defaultInputID = try controller.defaultInputDeviceID()
            let defaultOutputID = try controller.defaultOutputDeviceID()

            if selectedInputDeviceID == nil || !inputDevices.contains(where: { $0.id == selectedInputDeviceID }) {
                selectedInputDeviceID = inputDevices.first(where: { $0.id == defaultInputID })?.id ?? inputDevices.first?.id
            }
            if selectedOutputDeviceID == nil || !outputDevices.contains(where: { $0.id == selectedOutputDeviceID }) {
                selectedOutputDeviceID = outputDevices.first(where: { $0.id == defaultOutputID })?.id ?? outputDevices.first?.id
            }
            if selectedPluginID != nil && !plugins.contains(where: { $0.id == selectedPluginID }) {
                selectedPluginID = nil
            }

            handleDeviceSelectionChange()
            sanitizeThreadedProcessingBufferSize()
            if !isRunning {
                audioDropoutCount = 0
                droppedFrameCount = 0
            }
            statusMessage = isRunning ? "Running." : "Ready."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func currentThreadedProcessingBufferSize() -> Int {
        Int(threadedProcessingBufferSizeText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? normalizedThreadedProcessingBufferSize()
    }

    private func normalizedThreadedProcessingBufferSize() -> Int {
        let defaultValue = max(selectedBufferSize * 4, selectedBufferSize)
        let parsedValue = Int(threadedProcessingBufferSizeText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? defaultValue
        let minimum = max(1, selectedBufferSize)
        let maximum = 16_384
        let clamped = min(max(parsedValue, minimum), maximum)
        let remainder = clamped % minimum
        if remainder == 0 {
            return clamped
        }
        return min(clamped + (minimum - remainder), maximum)
    }

    private func sanitizeThreadedProcessingBufferSize() {
        threadedProcessingBufferSizeText = String(normalizedThreadedProcessingBufferSize())
    }

    func handleDeviceSelectionChange() {
        if let inputDevice = selectedInputDevice {
            selectedInputChannel = min(max(1, selectedInputChannel), inputDevice.inputChannelCount)
        } else {
            selectedInputChannel = 1
        }

        if let outputDevice = selectedOutputDevice {
            selectedOutputChannel = min(max(1, selectedOutputChannel), outputDevice.outputChannelCount)
        } else {
            selectedOutputChannel = 1
        }

        if let preferredBufferSize = DefaultBufferSizes.preferredHardwareBufferSize(from: availableBufferSizes) {
            if !isSelectedBufferSizeValid {
                selectedBufferSize = preferredBufferSize
            }
        }

        customBufferSizeText = String(selectedBufferSize)
        sanitizeThreadedProcessingBufferSize()
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
        sanitizeThreadedProcessingBufferSize()
        statusMessage = "Ready."
    }

    func applyThreadedProcessingBufferSize() {
        if let message = threadedProcessingValidationMessage {
            statusMessage = message
            threadedProcessingBufferSizeText = String(normalizedThreadedProcessingBufferSize())
            return
        }

        threadedProcessingBufferSizeText = String(currentThreadedProcessingBufferSize())
        statusMessage = "Ready."
    }

    func toggleStartStop() {
        if isRunning {
            audioDropoutMonitorTask?.cancel()
            audioDropoutMonitorTask = nil
            audioDropoutCount = controller.audioDropoutCount()
            droppedFrameCount = controller.droppedFrameCount()
            updateTelemetry()
            controller.stop()
            isRunning = false
            statusMessage = "Stopped."
            return
        }

        guard canStart else {
            statusMessage = "Please select valid devices, channels, and a buffer size."
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
                self.statusMessage = configuration.plugin == nil ? "Running in bypass." : "Running."
            } catch {
                self.audioDropoutMonitorTask?.cancel()
                self.audioDropoutMonitorTask = nil
                self.audioDropoutCount = self.controller.audioDropoutCount()
                self.droppedFrameCount = self.controller.droppedFrameCount()
                self.updateTelemetry()
                self.statusMessage = error.localizedDescription
                self.controller.stop()
                self.isRunning = false
            }

            self.isBusy = false
        }
    }

    func resetDropoutCounters() {
        controller.resetDropoutCounters()
        audioDropoutCount = controller.audioDropoutCount()
        droppedFrameCount = controller.droppedFrameCount()
        updateTelemetry()
    }

    private func makeConfiguration() throws -> AudioHostConfiguration {
        guard
            let inputDevice = selectedInputDevice,
            let outputDevice = selectedOutputDevice
        else {
            throw AudioHostError("Select both an input and an output interface before starting.")
        }

        let plugin = plugins.first { $0.id == selectedPluginID }

        return AudioHostConfiguration(
            inputDevice: inputDevice,
            outputDevice: outputDevice,
            bufferSize: selectedBufferSize,
            inputChannel: selectedInputChannel,
            outputChannel: selectedOutputChannel,
            plugin: plugin,
            threadedProcessingEnabled: threadedProcessingEnabled,
            threadedProcessingBufferSize: currentThreadedProcessingBufferSize()
        )
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
                    self.updateTelemetry()
                    self.controller.stop()
                    self.isRunning = false
                    self.statusMessage = runtimeStatus
                    return
                }
                self.audioDropoutCount = self.controller.audioDropoutCount()
                self.droppedFrameCount = self.controller.droppedFrameCount()
                self.updateTelemetry()
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private func updateTelemetry() {
        let telemetry = controller.telemetrySnapshot()
        telemetrySummary = "Callbacks in/out/effect: \(telemetry.peakInputCallbackFrames) / \(telemetry.peakOutputCallbackFrames) / \(telemetry.peakEffectRenderFrames) frames"
        ringTelemetrySummary = "Peak ring occupancy in/out: \(telemetryOccupancyString(telemetry.peakInputRingOccupancyFrames, capacity: telemetry.inputRingCapacityFrames)) / \(telemetryOccupancyString(telemetry.peakOutputRingOccupancyFrames, capacity: telemetry.outputRingCapacityFrames))"
    }

    private func telemetryOccupancyString(_ frames: UInt64, capacity: Int) -> String {
        guard capacity > 0 else {
            return "\(frames) frames"
        }
        let percent = Double(frames) / Double(capacity) * 100
        return "\(frames) frames (\(Int(percent.rounded()))%)"
    }

    private func setupPersistenceObservers() {
        $selectedInputDeviceID
            .dropFirst()
            .sink { [weak self] _ in
                self?.persistSettings()
            }
            .store(in: &persistenceCancellables)

        $selectedOutputDeviceID
            .dropFirst()
            .sink { [weak self] _ in
                self?.persistSettings()
            }
            .store(in: &persistenceCancellables)

        $selectedInputChannel
            .dropFirst()
            .sink { [weak self] _ in
                self?.persistSettings()
            }
            .store(in: &persistenceCancellables)

        $selectedOutputChannel
            .dropFirst()
            .sink { [weak self] _ in
                self?.persistSettings()
            }
            .store(in: &persistenceCancellables)

        $selectedBufferSize
            .dropFirst()
            .sink { [weak self] _ in
                self?.persistSettings()
            }
            .store(in: &persistenceCancellables)

        $selectedPluginID
            .dropFirst()
            .sink { [weak self] _ in
                self?.persistSettings()
            }
            .store(in: &persistenceCancellables)

        $threadedProcessingEnabled
            .dropFirst()
            .sink { [weak self] _ in
                self?.persistSettings()
            }
            .store(in: &persistenceCancellables)

        $threadedProcessingBufferSizeText
            .dropFirst()
            .sink { [weak self] _ in
                self?.persistSettings()
            }
            .store(in: &persistenceCancellables)
    }

    private func persistSettings() {
        let settings = PersistedSettings(
            inputDeviceID: selectedInputDeviceID,
            outputDeviceID: selectedOutputDeviceID,
            inputChannel: selectedInputChannel,
            outputChannel: selectedOutputChannel,
            bufferSize: selectedBufferSize,
            pluginID: selectedPluginID,
            threadedProcessingEnabled: threadedProcessingEnabled,
            threadedProcessingBufferSize: currentThreadedProcessingBufferSize()
        )

        guard let data = try? JSONEncoder().encode(settings) else {
            return
        }

        userDefaults.set(data, forKey: Self.persistedSettingsKey)
    }
}
