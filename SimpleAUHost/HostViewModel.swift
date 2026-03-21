import AVFoundation
import SwiftUI

@MainActor
final class HostViewModel: ObservableObject {
    @Published private(set) var inputDevices: [AudioDeviceInfo] = []
    @Published private(set) var outputDevices: [AudioDeviceInfo] = []
    @Published private(set) var plugins: [AudioUnitPluginInfo] = []

    @Published var selectedInputDeviceID: AudioDeviceID?
    @Published var selectedOutputDeviceID: AudioDeviceID?
    @Published var selectedInputChannel: Int = 1
    @Published var selectedOutputChannel: Int = 1
    @Published var selectedBufferSize: Int = 128
    @Published var customBufferSizeText = "128"
    @Published var selectedPluginID: String?

    @Published var isRunning = false
    @Published var isBusy = false
    @Published var statusMessage = "Ready."
    @Published private(set) var audioDropoutCount: UInt64 = 0

    private let controller = AudioHostController()
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

            handleDeviceSelectionChange()
            if !isRunning {
                audioDropoutCount = 0
            }
            statusMessage = isRunning ? "Running." : "Ready."
        } catch {
            statusMessage = error.localizedDescription
        }
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

        if let firstBuffer = availableBufferSizes.first {
            if !isSelectedBufferSizeValid {
                selectedBufferSize = firstBuffer
            }
        }

        customBufferSizeText = String(selectedBufferSize)
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
        statusMessage = "Ready."
    }

    func toggleStartStop() {
        if isRunning {
            audioDropoutMonitorTask?.cancel()
            audioDropoutMonitorTask = nil
            audioDropoutCount = controller.audioDropoutCount()
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
                self.startAudioDropoutMonitoring()
                self.statusMessage = configuration.plugin == nil ? "Running in bypass." : "Running."
            } catch {
                self.audioDropoutMonitorTask?.cancel()
                self.audioDropoutMonitorTask = nil
                self.audioDropoutCount = self.controller.audioDropoutCount()
                self.statusMessage = error.localizedDescription
                self.controller.stop()
                self.isRunning = false
            }

            self.isBusy = false
        }
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
            plugin: plugin
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
                self.audioDropoutCount = self.controller.audioDropoutCount()
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }
}
