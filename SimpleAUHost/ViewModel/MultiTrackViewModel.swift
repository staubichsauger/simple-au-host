import AVFoundation
import Combine
import SwiftUI

enum StartupSavedSessionSelection: String, CaseIterable, Identifiable {
    case lastSaved
    case specific

    var id: String { rawValue }

    var title: String {
        switch self {
        case .lastSaved:
            "Last Saved Show"
        case .specific:
            "Specific Show"
        }
    }
}

@MainActor
final class MultiTrackViewModel: ObservableObject {
    struct SessionDeviceResolutionAlert: Identifiable {
        let id = UUID()
        let message: String
    }

    struct StartFailureAlert: Identifiable {
        let id = UUID()
        let messages: [String]

        var message: String {
            messages.joined(separator: "\n")
        }
    }

    struct SessionReloadRetryContext {
        let sessionURL: URL
        let reopensAsTemplate: Bool
    }

    @Published private(set) var inputDevices: [AudioDeviceInfo] = []
    @Published private(set) var outputDevices: [AudioDeviceInfo] = []
    @Published private(set) var plugins: [AudioUnitPluginInfo] = []
    @Published var selectedInputDeviceID: AudioDeviceID?
    @Published var selectedOutputDeviceID: AudioDeviceID?
    @Published var selectedBufferSize: Int = DefaultBufferSizes.hardwareFrames
    @Published var customBufferSizeText = String(DefaultBufferSizes.hardwareFrames)
    @Published var bufferedInternalBufferText = String(DefaultBufferSizes.bufferedFrames)
    @Published var broadcastInternalBufferText = String(DefaultBufferSizes.broadcastFrames)
    @Published var broadcastPrerollMultiplier = DefaultBufferSizes.broadcastPrerollMultiplier
    @Published var tracks: [MultiTrackTrackConfiguration] = []
    @Published var isRunning = false
    @Published var isBusy = false
    @Published var statusMessage = "Ready."
    @Published private(set) var embeddedPluginEditorSession: MultiTrackAudioHostController.HostedPluginEditorSession?
    @Published private(set) var embeddedPluginEditorTrackID: UUID?
    @Published private(set) var embeddedPluginEditorPluginID: UUID?
    @Published private(set) var audioDropoutCount: UInt64 = 0
    @Published private(set) var droppedFrameCount: UInt64 = 0
    @Published private(set) var telemetrySummary = "Callbacks in/out: 0 / 0 frames"
    @Published private(set) var ringTelemetrySummary = "Peak ring occupancy in/out: 0 / 0 frames"
    @Published private(set) var workerTelemetrySummary = "Workers: 0 shards, track/shard render: 0 / 0 us, util: 0%, wakeups: 0/s"
    @Published private(set) var realtimeTelemetrySummary = "Realtime: 0 tracks, render avg/peak 0 / 0 us"
    @Published private(set) var bufferedTelemetrySummary = "Buffered: 0 tracks, 0 shards, track/shard avg 0 / 0 us, peak 0 / 0 us, util 0%, wakeups 0/s"
    @Published private(set) var broadcastTelemetrySummary = "Broadcast: 0 tracks, 0 shards, track/shard avg 0 / 0 us, peak 0 / 0 us, util 0%, wakeups 0/s"
    @Published var currentSessionName = "Untitled Session"
    @Published var sessionWarnings: [String] = []
    @Published var managedSessions: [ManagedSessionFile] = []
    @Published var hasUnsavedChanges = false
    @Published var sessionDeviceResolutionAlert: SessionDeviceResolutionAlert?
    @Published var startFailureAlert: StartFailureAlert?
    @Published var launchesIntoPerformViewOnStartup = false
    @Published var loadsSavedSessionOnStartup = false
    @Published var startsEngineOnLaunch = false
    @Published var startupSavedSessionSelection: StartupSavedSessionSelection = .lastSaved
    @Published var startupSpecificSessionURL: URL?
    @Published var opensStartupSpecificSessionAsTemplate = false
    @Published var lastSavedSessionURL: URL?
    @Published var companionControlEndpointURLString = CompanionControlDefaults.baseURLString
    @Published var companionControlStatus = "Starting local Companion control API..."
    @Published var tuneState = MultiTrackTuneState()
    @Published private var trackPluginLatencyFrames: [UUID: Int] = [:]

    private let catalog = AudioHostController()
    let controller = MultiTrackAudioHostController()
    let companionControlServer = CompanionControlServer()
    let startupPreferencesStore: StartupPreferencesStore
    var latencyBufferSettings = MultiTrackLatencyBufferSettings(hardwareBufferSize: DefaultBufferSizes.hardwareFrames)
    private var audioDropoutMonitorTask: Task<Void, Never>?
    private var startupDropoutResetTask: Task<Void, Never>?
    var currentSessionURL: URL?
    private var telemetryPublishingEnabled = false
    var copiedTrackProcessing: CopiedTrackProcessing?
    private var persistenceCancellables = Set<AnyCancellable>()
    var isApplyingSessionState = false
    var hasAppliedStartupSessionPreference = false
    private var hasAppliedStartupEnginePreference = false
    var isCurrentSessionStartupTemplate = false
    var sessionReloadRetryContext: SessionReloadRetryContext?

    init(userDefaults: UserDefaults = .standard) {
        self.startupPreferencesStore = StartupPreferencesStore(userDefaults: userDefaults)
        loadPersistedStartupPreferences()
        setupSessionChangeObservers()
        setupPluginRegistrationObserver()
        startCompanionControlServer()
    }

    deinit {
        audioDropoutMonitorTask?.cancel()
        startupDropoutResetTask?.cancel()
        companionControlServer.stop()
        let controller = controller
        Task { @MainActor in
            controller.closePluginEditorWindows()
        }
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

    var selectedAudioDeviceID: AudioDeviceID? {
        get { selectedInputDeviceID }
        set {
            selectedInputDeviceID = newValue
            selectedOutputDeviceID = newValue
        }
    }

    var hasStoredSessionFile: Bool {
        currentSessionURL != nil
    }

    var currentSessionDisplayName: String {
        currentSessionName + (hasUnsavedChanges ? " *" : "")
    }

    var lastSavedSessionDisplayName: String {
        guard let lastSavedSessionURL else { return "No saved show recorded yet." }
        return sessionDisplayName(for: lastSavedSessionURL)
    }

    var lastSavedSessionPath: String? {
        lastSavedSessionURL?.path
    }

    var lastSavedSessionExists: Bool {
        guard let lastSavedSessionURL else { return false }
        return FileManager.default.fileExists(atPath: lastSavedSessionURL.path)
    }

    var startupSpecificSessionDisplayName: String {
        guard let startupSpecificSessionURL else { return "No startup show selected." }
        return sessionDisplayName(for: startupSpecificSessionURL)
    }

    var startupSpecificSessionPath: String? {
        startupSpecificSessionURL?.path
    }

    var startupSpecificSessionExists: Bool {
        guard let startupSpecificSessionURL else { return false }
        return FileManager.default.fileExists(atPath: startupSpecificSessionURL.path)
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
        let trackMessages = tracks.compactMap { validateTrack($0) }
        if let overlapMessage = validateExclusiveOutputRouting(for: tracks.filter(\.isEnabled)) {
            return trackMessages + [overlapMessage]
        }
        return trackMessages
    }

    var latencyBufferValidationMessages: [String] {
        [
            validateLatencyBufferText(bufferedInternalBufferText, for: .buffered),
            validateLatencyBufferText(broadcastInternalBufferText, for: .broadcast)
        ]
        .compactMap { $0 }
    }

    func load() {
        Task {
            await loadAsync()
        }
    }

    func loadAsync() async {
        let existingHasUnsavedChanges = hasUnsavedChanges
        isBusy = true
        defer { isBusy = false }

        do {
            let (allDevices, availablePlugins, sessions) = try await Task.detached(priority: .userInitiated) { [catalog] in
                _ = try SAHManagedSessionStore.ensureDirectories()
                return (
                    try catalog.availableDevices(),
                    try catalog.availablePlugins(),
                    try SAHManagedSessionStore.managedSessions()
                )
            }.value

            isApplyingSessionState = true
            let duplexDevices = allDevices.filter { $0.inputChannelCount > 0 && $0.outputChannelCount > 0 }
            inputDevices = duplexDevices
            outputDevices = duplexDevices
            plugins = availablePlugins

            if selectedInputDeviceID == nil {
                let defaultInputID = try? catalog.defaultInputDeviceID()
                let defaultOutputID = try? catalog.defaultOutputDeviceID()
                selectedAudioDeviceID =
                    inputDevices.first(where: { $0.id == defaultInputID })?.id ??
                    inputDevices.first(where: { $0.id == defaultOutputID })?.id ??
                    inputDevices.first?.id
            }
            selectedOutputDeviceID = selectedInputDeviceID

            if tracks.isEmpty {
                addTrack(layout: .mono)
            }

            sanitizeTracks(clampTrackRouting: false)
            sanitizeLatencyBufferSettings()
            tuneState.normalize()
            updateSessionWarnings()
            managedSessions = sessions
            updateSessionNameIfNeeded()
            if !isRunning {
                audioDropoutCount = 0
                droppedFrameCount = 0
            }
            statusMessage = isRunning ? "Running." : "Ready."
            isApplyingSessionState = false
            hasUnsavedChanges = existingHasUnsavedChanges
        } catch {
            isApplyingSessionState = false
            statusMessage = error.localizedDescription
        }
    }

    func applyStartupEnginePreferenceIfNeeded() {
        guard !hasAppliedStartupEnginePreference else { return }
        hasAppliedStartupEnginePreference = true

        guard startsEngineOnLaunch else { return }
        startEngine()
    }

    func handleDeviceSelectionChange() {
        selectedOutputDeviceID = selectedInputDeviceID
        sanitizeTracks(clampTrackRouting: false)
        updateSessionWarnings()
    }

    func openPluginEditor(for trackID: UUID) {
        openPluginEditor(for: trackID, pluginID: nil)
    }

    func openPluginEditor(for trackID: UUID, pluginID: UUID?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await controller.openPluginEditor(for: trackID, pluginID: pluginID)
            } catch {
                statusMessage = error.localizedDescription
            }
        }
    }

    func showEmbeddedPluginEditor(for trackID: UUID, pluginID: UUID?) {
        guard isRunning else {
            clearEmbeddedPluginEditor()
            return
        }
        guard embeddedPluginEditorTrackID != trackID || embeddedPluginEditorPluginID != pluginID || embeddedPluginEditorSession == nil else {
            return
        }

        let previousSession = embeddedPluginEditorSession
        embeddedPluginEditorSession = nil
        embeddedPluginEditorTrackID = trackID
        embeddedPluginEditorPluginID = pluginID
        previousSession?.invalidate()

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let session = try await controller.makeHostedPluginEditorSession(for: trackID, pluginID: pluginID)
                guard self.embeddedPluginEditorTrackID == trackID,
                      self.embeddedPluginEditorPluginID == pluginID else {
                    session.invalidate()
                    return
                }
                self.embeddedPluginEditorSession = session
            } catch {
                guard self.embeddedPluginEditorTrackID == trackID,
                      self.embeddedPluginEditorPluginID == pluginID else {
                    return
                }
                self.embeddedPluginEditorTrackID = nil
                self.embeddedPluginEditorPluginID = nil
                self.embeddedPluginEditorSession = nil
                self.statusMessage = error.localizedDescription
            }
        }
    }

    func clearEmbeddedPluginEditor() {
        embeddedPluginEditorSession?.invalidate()
        embeddedPluginEditorSession = nil
        embeddedPluginEditorTrackID = nil
        embeddedPluginEditorPluginID = nil
    }

    func popOutEmbeddedPluginEditor() {
        guard let trackID = embeddedPluginEditorTrackID else { return }
        let pluginID = embeddedPluginEditorPluginID
        clearEmbeddedPluginEditor()
        openPluginEditor(for: trackID, pluginID: pluginID)
    }

    func canOpenPluginEditor(for track: MultiTrackTrackConfiguration) -> Bool {
        isRunning && track.hasPlugins
    }

    func canOpenPluginEditor(for plugin: MultiTrackTrackConfiguration.PluginInsert) -> Bool {
        isRunning && plugin.pluginID != nil
    }

    func addPluginInsert(to trackID: UUID) {
        guard let trackIndex = tracks.firstIndex(where: { $0.id == trackID }) else { return }
        tracks[trackIndex].plugins.append(.init())
        updateSessionWarnings()
    }

    func removePluginInsert(trackID: UUID, pluginID: UUID) {
        guard let trackIndex = tracks.firstIndex(where: { $0.id == trackID }) else { return }
        tracks[trackIndex].plugins.removeAll { $0.id == pluginID }
        updateSessionWarnings()
    }

    func movePluginInsert(trackID: UUID, pluginID: UUID, direction: Int) {
        guard let trackIndex = tracks.firstIndex(where: { $0.id == trackID }) else { return }
        guard let pluginIndex = tracks[trackIndex].plugins.firstIndex(where: { $0.id == pluginID }) else { return }
        let targetIndex = pluginIndex + direction
        guard tracks[trackIndex].plugins.indices.contains(targetIndex) else { return }
        let plugin = tracks[trackIndex].plugins.remove(at: pluginIndex)
        tracks[trackIndex].plugins.insert(plugin, at: targetIndex)
    }

    func pluginInsertLabel(for plugin: MultiTrackTrackConfiguration.PluginInsert, index: Int) -> String {
        if let pluginID = plugin.pluginID,
           let pluginInfo = plugins.first(where: { $0.id == pluginID }) {
            return "\(index + 1). \(pluginInfo.name)"
        }
        return "\(index + 1). Empty insert"
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
        updateSessionWarnings()
    }

    func availableInputStartChannels(for track: MultiTrackTrackConfiguration) -> [Int] {
        guard let selectedInputDevice else { return [track.inputStartChannel] }
        let maxStart = max(1, selectedInputDevice.inputChannelCount - track.channelCount + 1)
        return Array(Set(Array(1...maxStart) + [track.inputStartChannel])).sorted()
    }

    func availableOutputStartChannels(for track: MultiTrackTrackConfiguration) -> [Int] {
        guard let selectedOutputDevice else { return [track.outputStartChannel] }
        let maxStart = max(1, selectedOutputDevice.outputChannelCount - track.channelCount + 1)
        let availableChannels = Array(1...maxStart).filter { candidate in
            outputChannelsAreAvailable(
                for: sanitizedTrack(track),
                proposedStartChannel: candidate
            )
        }
        return Array(Set(availableChannels + [track.outputStartChannel])).sorted()
    }

    func inputRoutingIsValid(for track: MultiTrackTrackConfiguration) -> Bool {
        guard let selectedInputDevice else { return false }
        return track.inputStartChannel >= 1 &&
            track.inputStartChannel + track.channelCount - 1 <= selectedInputDevice.inputChannelCount
    }

    func outputRoutingIsValid(for track: MultiTrackTrackConfiguration) -> Bool {
        guard let selectedOutputDevice else { return false }
        guard track.outputStartChannel >= 1,
              track.outputStartChannel + track.channelCount - 1 <= selectedOutputDevice.outputChannelCount else {
            return false
        }
        return outputChannelsAreAvailable(for: track, proposedStartChannel: track.outputStartChannel)
    }

    func internalBufferDescription(for track: MultiTrackTrackConfiguration) -> String {
        let internalFrames = latencyBufferSettings.internalFrames(
            for: track.latencyClass,
            hardwareBufferSize: selectedBufferSize
        )
        return "\(track.latencyClass.title): \(internalFrames) internal frames"
    }

    func latencyReadout(for track: MultiTrackTrackConfiguration) -> String {
        let internalFrames = latencyBufferSettings.internalFrames(
            for: track.latencyClass,
            hardwareBufferSize: selectedBufferSize
        )
        let latencyClassFrames = max(0, internalFrames - selectedBufferSize)
        let broadcastSafetyFrames = track.latencyClass == .broadcast
            ? max(0, latencyBufferSettings.broadcastPrerollMultiplier - 1) * internalFrames
            : 0
        let pluginLatencyFrames = trackPluginLatencyFrames[track.id] ?? 0
        let addedFrames = latencyClassFrames + broadcastSafetyFrames + pluginLatencyFrames
        let sampleRate = selectedInputDevice?.nominalSampleRate ?? selectedOutputDevice?.nominalSampleRate ?? 0
        guard sampleRate > 0 else {
            return "+\(addedFrames) fr"
        }
        let milliseconds = Double(addedFrames) / sampleRate * 1_000
        return "+\(addedFrames) fr / \(Self.latencyFormatter.string(from: NSNumber(value: milliseconds)) ?? "0.0") ms"
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

    func setBroadcastPrerollMultiplier(_ multiplier: Int) {
        let sanitizedMultiplier = normalizedBroadcastPrerollMultiplier(multiplier)
        broadcastPrerollMultiplier = sanitizedMultiplier
        latencyBufferSettings.broadcastPrerollMultiplier = sanitizedMultiplier
        statusMessage = "Ready."
    }

    func toggleStartStop() {
        if isRunning {
            stopEngine()
            return
        }

        startEngine()
    }

    func startEngine() {
        guard canStart else {
            if presentSessionDeviceResolutionAlertIfNeeded() {
                return
            }
            presentStartFailureAlert(messages: startValidationFailureMessages())
            return
        }

        isBusy = true
        statusMessage = "Requesting microphone access..."

        Task { [weak self] in
            guard let self else { return }

            let granted = await self.requestMicrophoneAccessIfNeeded()
            guard granted else {
                self.isBusy = false
                self.presentStartFailureAlert(messages: ["Microphone access was not granted."])
                return
            }

            do {
                let configuration = try self.makeConfiguration()
                try self.controller.start(configuration: configuration)
                _ = try self.controller.setTuneBypassed(!self.tuneState.isEnabled)
                _ = try self.controller.applyTuneKeySelection(self.tuneState.appliedKey.normalized)
                self.syncTuneStrengthSelectionsFromRunningEngine()
                self.isRunning = true
                self.refreshTrackPluginLatencyFrames()
                self.refreshPublishedTelemetry()
                self.startAudioDropoutMonitoring()
                self.scheduleStartupDropoutReset()
                self.statusMessage = "Running."
            } catch {
                self.audioDropoutMonitorTask?.cancel()
                self.audioDropoutMonitorTask = nil
                self.startupDropoutResetTask?.cancel()
                self.startupDropoutResetTask = nil
                self.refreshPublishedTelemetry()
                self.clearEmbeddedPluginEditor()
                self.controller.stop()
                self.isRunning = false
                self.trackPluginLatencyFrames = [:]
                self.presentStartFailureAlert(messages: [error.localizedDescription])
            }

            self.isBusy = false
        }
    }

    private func presentStartFailureAlert(messages: [String]) {
        let normalizedMessages = messages
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let displayMessages = normalizedMessages.isEmpty
            ? ["Please complete the device and track configuration."]
            : normalizedMessages

        startFailureAlert = StartFailureAlert(messages: displayMessages)
        statusMessage = displayMessages.first ?? "Engine failed to start."
    }

    private func startValidationFailureMessages() -> [String] {
        var messages: [String] = []

        if selectedInputDevice == nil {
            messages.append("Select an input interface.")
        }
        if selectedOutputDevice == nil {
            messages.append("Select an output interface.")
        }
        if !isSelectedBufferSizeValid {
            messages.append(bufferSizeHelpText)
        }

        messages.append(contentsOf: latencyBufferValidationMessages)

        if !tracks.contains(where: \.isEnabled) {
            messages.append("Enable at least one track.")
        }

        messages.append(contentsOf: invalidTrackMessages)
        return messages
    }

    private func stopEngine() {
        beginStoppingEngine(finalStatusMessage: "Stopped.")
    }

    private func beginStoppingEngine(
        finalStatusMessage: String,
        interimStatusMessage: String = "Stopping..."
    ) {
        clearEmbeddedPluginEditor()
        controller.closePluginEditorWindows()
        audioDropoutMonitorTask?.cancel()
        audioDropoutMonitorTask = nil
        startupDropoutResetTask?.cancel()
        startupDropoutResetTask = nil
        refreshPublishedTelemetry()
        captureLivePluginStates()
        controller.beginStop()
        isRunning = false
        isBusy = true
        trackPluginLatencyFrames = [:]
        statusMessage = interimStatusMessage

        let controller = self.controller
        Task { [weak self, controller] in
            await Task.detached(priority: .userInitiated) {
                controller.joinStopped()
            }.value

            guard let self else { return }
            self.refreshPublishedTelemetry()
            self.isBusy = false
            self.statusMessage = finalStatusMessage
        }
    }

    func addTrack(layout: TrackChannelLayout) {
        let trackNumber = tracks.count + 1
        tracks.append(
            MultiTrackTrackConfiguration(
                name: layout == .mono ? "Track \(trackNumber)" : "Stereo \(trackNumber)",
                layout: layout
            )
        )
        sanitizeTracks()
    }

    func normalizedBroadcastPrerollMultiplier(_ value: Int) -> Int {
        MultiTrackValidation.normalizedBroadcastPrerollMultiplier(value)
    }

    func updateSessionWarnings() {
        var warnings: [String] = []

        if sessionReloadRetryContext != nil, selectedInputDevice == nil {
            warnings.append("Saved input device is not currently available. Reconnect it or choose another input before starting.")
        } else if let selectedInputDeviceID, !inputDevices.contains(where: { $0.id == selectedInputDeviceID }) {
            warnings.append("Saved input device is not currently available. Reconnect it or choose another input before starting.")
        }

        if sessionReloadRetryContext != nil, selectedOutputDevice == nil {
            warnings.append("Saved output device is not currently available. Reconnect it or choose another output before starting.")
        } else if let selectedOutputDeviceID, !outputDevices.contains(where: { $0.id == selectedOutputDeviceID }) {
            warnings.append("Saved output device is not currently available. Reconnect it or choose another output before starting.")
        }

        let availablePluginIDs = Set(plugins.map(\.id))
        for track in tracks where track.isEnabled {
            for insert in track.plugins {
                if let pluginID = insert.pluginID, !availablePluginIDs.contains(pluginID) {
                    warnings.append("\(track.name) references a plugin that is not currently installed: \(pluginID)")
                }
            }
        }

        sessionWarnings = warnings
    }

    func normalizedInternalBufferSize(_ value: Int) -> Int {
        MultiTrackValidation.normalizedInternalBufferSize(
            value,
            hardwareBufferSize: selectedBufferSize
        )
    }

    private func validateLatencyBufferText(
        _ text: String,
        for latencyClass: TrackLatencyClass
    ) -> String? {
        MultiTrackValidation.validateLatencyBufferText(
            text,
            for: latencyClass,
            hardwareBufferSize: selectedBufferSize
        )
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

    func sanitizedTrack(_ track: MultiTrackTrackConfiguration) -> MultiTrackTrackConfiguration {
        MultiTrackValidation.sanitizedTrack(
            track,
            inputDevice: selectedInputDevice,
            outputDevice: selectedOutputDevice
        )
    }

    private func validateTrack(_ track: MultiTrackTrackConfiguration) -> String? {
        MultiTrackValidation.validateTrack(
            track,
            inputDevice: selectedInputDevice,
            outputDevice: selectedOutputDevice,
            availablePluginIDs: Set(plugins.map(\.id))
        )
    }

    private func validateExclusiveOutputRouting(
        for tracks: [MultiTrackTrackConfiguration]
    ) -> String? {
        MultiTrackValidation.validateExclusiveOutputRouting(for: tracks)
    }

    private func outputChannelsAreAvailable(
        for track: MultiTrackTrackConfiguration,
        proposedStartChannel: Int
    ) -> Bool {
        MultiTrackValidation.outputChannelsAreAvailable(
            for: track,
            proposedStartChannel: proposedStartChannel,
            tracks: tracks
        )
    }

    private func makeConfiguration() throws -> MultiTrackHostConfiguration {
        guard
            let inputDevice = selectedInputDevice,
            let outputDevice = selectedOutputDevice
        else {
            throw AudioHostError("Select both an input and an output interface before starting.")
        }

        let sanitizedTracks = tracks.filter(\.isEnabled)

        guard !sanitizedTracks.isEmpty else {
            throw AudioHostError("Enable at least one track before starting.")
        }
        if let firstLatencyError = latencyBufferValidationMessages.first {
            throw AudioHostError(firstLatencyError)
        }

        if let firstError = sanitizedTracks.compactMap(validateTrack).first {
            throw AudioHostError(firstError)
        }
        if let overlapError = validateExclusiveOutputRouting(for: sanitizedTracks) {
            throw AudioHostError(overlapError)
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
        refreshPublishedTelemetry()
    }

    private func scheduleStartupDropoutReset() {
        startupDropoutResetTask?.cancel()
        startupDropoutResetTask = Task { [weak self] in
            try? await Task.sleep(for: Self.startupDropoutGracePeriod)
            guard !Task.isCancelled, let self, self.isRunning else { return }
            self.controller.resetDropoutCounters()
            self.refreshPublishedTelemetry()
            self.startupDropoutResetTask = nil
        }
    }

    func setTelemetryPublishingEnabled(_ enabled: Bool) {
        telemetryPublishingEnabled = enabled
        guard enabled else { return }
        refreshPublishedTelemetry()
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
        let controller = self.controller
        audioDropoutMonitorTask = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }

                let runtimeStatus = controller.runtimeStatusMessage()
                let dropoutCount = controller.audioDropoutCount()
                let droppedFrameCount = controller.droppedFrameCount()
                let telemetry = controller.telemetrySnapshot()

                if let runtimeStatus {
                    await MainActor.run {
                        self.applyTelemetrySnapshot(
                            dropoutCount: dropoutCount,
                            droppedFrameCount: droppedFrameCount,
                            telemetry: telemetry
                        )
                        self.beginStoppingEngine(
                            finalStatusMessage: runtimeStatus,
                            interimStatusMessage: runtimeStatus
                        )
                    }
                    return
                }

                await MainActor.run {
                    guard self.telemetryPublishingEnabled else { return }
                    self.applyTelemetrySnapshot(
                        dropoutCount: dropoutCount,
                        droppedFrameCount: droppedFrameCount,
                        telemetry: telemetry
                    )
                }

                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    static let templateDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
    private static let latencyFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.minimumFractionDigits = 1
        formatter.maximumFractionDigits = 1
        return formatter
    }()
    private static let startupDropoutGracePeriod: Duration = .seconds(1)
}

private extension MultiTrackViewModel {
    func refreshPublishedTelemetry() {
        refreshTrackPluginLatencyFrames()
        applyTelemetrySnapshot(
            dropoutCount: controller.audioDropoutCount(),
            droppedFrameCount: controller.droppedFrameCount(),
            telemetry: controller.telemetrySnapshot()
        )
    }

    func refreshTrackPluginLatencyFrames() {
        guard isRunning else {
            trackPluginLatencyFrames = [:]
            return
        }

        trackPluginLatencyFrames = Dictionary(
            uniqueKeysWithValues: controller.trackPluginLatencySnapshot().map { snapshot in
                (snapshot.trackID, snapshot.pluginLatencyFrames)
            }
        )
    }

    func applyTelemetrySnapshot(
        dropoutCount: UInt64,
        droppedFrameCount: UInt64,
        telemetry: AudioEngineTelemetrySnapshot
    ) {
        audioDropoutCount = dropoutCount
        self.droppedFrameCount = droppedFrameCount
        let formattedTelemetry = EngineTelemetryFormatter.strings(for: telemetry)
        telemetrySummary = formattedTelemetry.telemetrySummary
        ringTelemetrySummary = formattedTelemetry.ringTelemetrySummary
        workerTelemetrySummary = formattedTelemetry.workerTelemetrySummary
        realtimeTelemetrySummary = formattedTelemetry.realtimeTelemetrySummary
        bufferedTelemetrySummary = formattedTelemetry.bufferedTelemetrySummary
        broadcastTelemetrySummary = formattedTelemetry.broadcastTelemetrySummary
    }

    func setupSessionChangeObservers() {
        $selectedInputDeviceID
            .dropFirst()
            .sink { [weak self] _ in
                self?.markSessionAsEdited()
            }
            .store(in: &persistenceCancellables)

        $selectedOutputDeviceID
            .dropFirst()
            .sink { [weak self] _ in
                self?.markSessionAsEdited()
            }
            .store(in: &persistenceCancellables)

        $selectedBufferSize
            .dropFirst()
            .sink { [weak self] _ in
                self?.markSessionAsEdited()
            }
            .store(in: &persistenceCancellables)

        $bufferedInternalBufferText
            .dropFirst()
            .sink { [weak self] _ in
                self?.markSessionAsEdited()
            }
            .store(in: &persistenceCancellables)

        $broadcastInternalBufferText
            .dropFirst()
            .sink { [weak self] _ in
                self?.markSessionAsEdited()
            }
            .store(in: &persistenceCancellables)

        $broadcastPrerollMultiplier
            .dropFirst()
            .sink { [weak self] _ in
                self?.markSessionAsEdited()
            }
            .store(in: &persistenceCancellables)

        $tracks
            .dropFirst()
            .sink { [weak self] _ in
                self?.markSessionAsEdited()
            }
            .store(in: &persistenceCancellables)

        $tuneState
            .dropFirst()
            .sink { [weak self] _ in
                self?.markSessionAsEdited()
            }
            .store(in: &persistenceCancellables)
    }

    func markSessionAsEdited() {
        guard !isApplyingSessionState else { return }
        hasUnsavedChanges = true
    }

    /// Reloads the device/plugin catalog when Audio Unit registrations change
    /// (e.g. a plugin was installed while the app runs). The cache itself is
    /// invalidated by `AudioHostController`; this refresh updates the published
    /// plugin list, track validation, and session warnings. Debounced because
    /// the system can post the notification in bursts.
    func setupPluginRegistrationObserver() {
        NotificationCenter.default
            .publisher(for: .audioComponentRegistrationsChanged)
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.load()
                }
            }
            .store(in: &persistenceCancellables)
    }
}
