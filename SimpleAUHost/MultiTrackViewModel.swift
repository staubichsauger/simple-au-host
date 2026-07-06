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
    private struct CopiedTrackProcessing {
        let sourceTrackName: String
        let inserts: [MultiTrackTrackConfiguration.PluginInsert]
    }

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

    private struct SessionReloadRetryContext {
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
    @Published private(set) var currentSessionName = "Untitled Session"
    @Published private(set) var sessionWarnings: [String] = []
    @Published private(set) var managedSessions: [ManagedSessionFile] = []
    @Published private(set) var hasUnsavedChanges = false
    @Published var sessionDeviceResolutionAlert: SessionDeviceResolutionAlert?
    @Published var startFailureAlert: StartFailureAlert?
    @Published var launchesIntoPerformViewOnStartup = false
    @Published var loadsSavedSessionOnStartup = false
    @Published var startsEngineOnLaunch = false
    @Published var startupSavedSessionSelection: StartupSavedSessionSelection = .lastSaved
    @Published var startupSpecificSessionURL: URL?
    @Published var opensStartupSpecificSessionAsTemplate = false
    @Published private(set) var lastSavedSessionURL: URL?
    @Published private(set) var companionControlEndpointURLString = CompanionControlDefaults.baseURLString
    @Published private(set) var companionControlStatus = "Starting local Companion control API..."
    @Published var wavesTuneState = MultiTrackWavesTuneState()
    @Published private var trackPluginLatencyFrames: [UUID: Int] = [:]

    private let catalog = AudioHostController()
    private let controller = MultiTrackAudioHostController()
    private let companionControlServer = CompanionControlServer()
    private let userDefaults: UserDefaults
    private var latencyBufferSettings = MultiTrackLatencyBufferSettings(hardwareBufferSize: DefaultBufferSizes.hardwareFrames)
    private var audioDropoutMonitorTask: Task<Void, Never>?
    private var startupDropoutResetTask: Task<Void, Never>?
    private var currentSessionURL: URL?
    private var telemetryPublishingEnabled = false
    private var copiedTrackProcessing: CopiedTrackProcessing?
    private var persistenceCancellables = Set<AnyCancellable>()
    private var isApplyingSessionState = false
    private var hasAppliedStartupSessionPreference = false
    private var hasAppliedStartupEnginePreference = false
    private var isCurrentSessionStartupTemplate = false
    private var sessionReloadRetryContext: SessionReloadRetryContext?

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        loadPersistedStartupPreferences()
        setupSessionChangeObservers()
        startCompanionControlServer()
    }

    deinit {
        audioDropoutMonitorTask?.cancel()
        startupDropoutResetTask?.cancel()
        companionControlServer.stop()
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

    var configuredWavesTuneRealtimeInsertCount: Int {
        tracks
            .filter(\.isEnabled)
            .reduce(into: 0) { count, track in
                for insert in track.plugins {
                    guard let pluginID = insert.pluginID,
                          let plugin = plugins.first(where: { $0.id == pluginID }),
                          isWavesTuneRealtimePlugin(plugin) else {
                        continue
                    }
                    count += 1
                }
            }
    }

    var performTracks: [MultiTrackTrackConfiguration] {
        tracks.filter(trackHasConfiguredWavesTuneRealtimeInsert)
    }

    var stagedWavesTuneKeyTitle: String {
        wavesTuneState.stagedKey.title
    }

    var appliedWavesTuneKeyTitle: String {
        wavesTuneState.appliedKey.title
    }

    var canApplyStagedWavesTuneKey: Bool {
        wavesTuneState.stagedKey.normalized != wavesTuneState.appliedKey.normalized
    }

    var wavesTuneSongs: [WavesTuneSongEntry] {
        wavesTuneState.songs
    }

    var selectedWavesTuneSong: WavesTuneSongEntry? {
        guard let selectedSongID = wavesTuneState.selectedSongID else { return nil }
        return wavesTuneState.songs.first { $0.id == selectedSongID }
    }

    var selectedWavesTuneSongIndex: Int? {
        guard let selectedSongID = wavesTuneState.selectedSongID else { return nil }
        return wavesTuneState.songs.firstIndex { $0.id == selectedSongID }
    }

    var selectedWavesTuneSongTitle: String {
        guard let selectedWavesTuneSongIndex else { return "No Song Selected" }
        return wavesTuneSongDisplayTitle(for: wavesTuneState.songs[selectedWavesTuneSongIndex], index: selectedWavesTuneSongIndex)
    }

    var selectedWavesTuneSongKeyTitle: String {
        selectedWavesTuneSong?.key.title ?? "Select a song to apply its key."
    }

    var previousWavesTuneSongIndex: Int? {
        guard !wavesTuneState.songs.isEmpty else { return nil }
        guard let selectedWavesTuneSongIndex else { return wavesTuneState.songs.count - 1 }
        let previousIndex = selectedWavesTuneSongIndex - 1
        return wavesTuneState.songs.indices.contains(previousIndex) ? previousIndex : nil
    }

    var nextWavesTuneSongIndex: Int? {
        guard !wavesTuneState.songs.isEmpty else { return nil }
        guard let selectedWavesTuneSongIndex else { return 0 }
        let nextIndex = selectedWavesTuneSongIndex + 1
        return wavesTuneState.songs.indices.contains(nextIndex) ? nextIndex : nil
    }

    var canSelectPreviousWavesTuneSong: Bool {
        guard let selectedWavesTuneSongIndex else { return false }
        return selectedWavesTuneSongIndex > 0
    }

    var canSelectNextWavesTuneSong: Bool {
        guard !wavesTuneState.songs.isEmpty else { return false }
        guard let selectedWavesTuneSongIndex else { return true }
        return selectedWavesTuneSongIndex < wavesTuneState.songs.count - 1
    }

    var canSaveStagedKeyToSelectedWavesTuneSong: Bool {
        selectedWavesTuneSongIndex != nil
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
            wavesTuneState.normalize()
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

    func applyStartupSessionPreferenceIfNeeded() {
        guard !hasAppliedStartupSessionPreference else { return }
        hasAppliedStartupSessionPreference = true

        guard loadsSavedSessionOnStartup else { return }

        let startupURL: URL?
        let missingSelectionMessage: String

        switch startupSavedSessionSelection {
        case .lastSaved:
            startupURL = lastSavedSessionURL
            missingSelectionMessage = "Save a show first before using Last Saved Show at launch."
        case .specific:
            startupURL = startupSpecificSessionURL
            missingSelectionMessage = "Choose a specific show in Setup > Settings to open at launch."
        }

        guard let startupURL else {
            statusMessage = missingSelectionMessage
            return
        }

        guard FileManager.default.fileExists(atPath: startupURL.path) else {
            statusMessage = "Startup show \(sessionDisplayName(for: startupURL)) is unavailable."
            return
        }

        do {
            try loadSession(from: startupURL)
            if startupSavedSessionSelection == .specific && opensStartupSpecificSessionAsTemplate {
                openCurrentSessionAsTemplate()
            }
        } catch {
            statusMessage = "Failed to load startup show \(sessionDisplayName(for: startupURL)): \(error.localizedDescription)"
        }
    }

    func applyStartupSessionPreferenceIfNeededAsync() async {
        guard !hasAppliedStartupSessionPreference else { return }
        hasAppliedStartupSessionPreference = true

        guard loadsSavedSessionOnStartup else { return }
        let startupURL: URL?
        switch startupSavedSessionSelection {
        case .lastSaved:
            startupURL = lastSavedSessionURL
        case .specific:
            startupURL = startupSpecificSessionURL
        }

        guard let startupURL else {
            statusMessage = "Choose a startup show before enabling automatic show loading."
            return
        }

        guard FileManager.default.fileExists(atPath: startupURL.path) else {
            statusMessage = "Startup show \(sessionDisplayName(for: startupURL)) is unavailable."
            return
        }

        do {
            try await loadSessionAsync(from: startupURL)
            if startupSavedSessionSelection == .specific && opensStartupSpecificSessionAsTemplate {
                openCurrentSessionAsTemplate()
            }
        } catch {
            statusMessage = "Failed to load startup show \(sessionDisplayName(for: startupURL)): \(error.localizedDescription)"
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

    func retrySessionDeviceResolution() {
        guard let retryContext = sessionReloadRetryContext else { return }

        sessionDeviceResolutionAlert = nil
        load()

        do {
            try loadSession(from: retryContext.sessionURL)
            if retryContext.reopensAsTemplate {
                openCurrentSessionAsTemplate()
            }
            startEngine()
        } catch {
            statusMessage = "Failed to reload \(sessionDisplayName(for: retryContext.sessionURL)): \(error.localizedDescription)"
        }
    }

    func createNewSession() {
        guard !isRunning else { return }
        isApplyingSessionState = true
        selectedAudioDeviceID = inputDevices.first?.id
        selectedBufferSize = DefaultBufferSizes.preferredHardwareBufferSize(from: availableBufferSizes) ?? DefaultBufferSizes.hardwareFrames
        customBufferSizeText = String(selectedBufferSize)
        latencyBufferSettings = MultiTrackLatencyBufferSettings(hardwareBufferSize: selectedBufferSize)
        bufferedInternalBufferText = String(latencyBufferSettings.bufferedFrames)
        broadcastInternalBufferText = String(latencyBufferSettings.broadcastFrames)
        broadcastPrerollMultiplier = latencyBufferSettings.broadcastPrerollMultiplier
        tracks = []
        addTrack(layout: .mono)
        wavesTuneState = MultiTrackWavesTuneState()
        currentSessionURL = nil
        isCurrentSessionStartupTemplate = false
        sessionReloadRetryContext = nil
        sessionDeviceResolutionAlert = nil
        startFailureAlert = nil
        currentSessionName = "Untitled Session"
        sessionWarnings = []
        statusMessage = "Ready."
        isApplyingSessionState = false
        hasUnsavedChanges = false
    }

    func sessionDocumentForExport() -> MultiTrackSessionDocument {
        MultiTrackSessionDocument(session: makeSessionFile())
    }

    func suggestedSessionFilename() -> String {
        if isCurrentSessionStartupTemplate {
            return sanitizedSessionFilename(from: "\(currentSessionName)-\(Self.templateDateFormatter.string(from: Date()))")
        }
        return sanitizedSessionFilename(from: currentSessionName)
    }

    func saveSession() throws {
        guard let currentSessionURL else {
            throw AudioHostError("Choose Save As to create a session file first.")
        }
        try saveSession(to: currentSessionURL)
    }

    func saveSession(to url: URL) throws {
        captureLivePluginStates()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(makeSessionFile())
        try data.write(to: url, options: .atomic)
        currentSessionURL = url
        isCurrentSessionStartupTemplate = false
        sessionReloadRetryContext = SessionReloadRetryContext(sessionURL: url, reopensAsTemplate: false)
        sessionDeviceResolutionAlert = nil
        currentSessionName = sessionDisplayName(for: url)
        recordLastSavedSessionURL(url)
        hasUnsavedChanges = false
        try refreshManagedSessions()
        statusMessage = "Saved \(currentSessionName)."
    }

    func saveSessionAsync() async throws {
        guard let currentSessionURL else {
            throw AudioHostError("Choose Save As to create a session file first.")
        }
        try await saveSessionAsync(to: currentSessionURL)
    }

    func saveSessionAsync(to url: URL) async throws {
        captureLivePluginStates()
        let sessionFile = makeSessionFile()
        try await Task.detached(priority: .userInitiated) {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(sessionFile)
            try data.write(to: url, options: .atomic)
        }.value

        currentSessionURL = url
        isCurrentSessionStartupTemplate = false
        sessionReloadRetryContext = SessionReloadRetryContext(sessionURL: url, reopensAsTemplate: false)
        sessionDeviceResolutionAlert = nil
        currentSessionName = sessionDisplayName(for: url)
        recordLastSavedSessionURL(url)
        hasUnsavedChanges = false
        managedSessions = try await Task.detached(priority: .userInitiated) {
            try SAHManagedSessionStore.managedSessions()
        }.value
        statusMessage = "Saved \(currentSessionName)."
    }

    func rememberExportedSessionURL(_ url: URL) {
        currentSessionURL = url
        isCurrentSessionStartupTemplate = false
        sessionReloadRetryContext = SessionReloadRetryContext(sessionURL: url, reopensAsTemplate: false)
        currentSessionName = sessionDisplayName(for: url)
        recordLastSavedSessionURL(url)
        statusMessage = "Saved \(currentSessionName)."
    }

    func loadSession(from url: URL) throws {
        let data = try Data(contentsOf: url)
        let session: MultiTrackSessionFile
        do {
            session = try JSONDecoder().decode(MultiTrackSessionFile.self, from: data)
        } catch {
            throw AudioHostError("Failed to read the multi-track session file: \(error.localizedDescription)")
        }
        try session.validateFormatVersion()
        sessionDeviceResolutionAlert = nil
        applySession(session, sourceURL: url)
        recordLastSavedSessionURL(url)
        try refreshManagedSessions()
    }

    func loadSessionAsync(from url: URL) async throws {
        let (session, sessions) = try await Task.detached(priority: .userInitiated) {
            let data = try Data(contentsOf: url)
            let decodedSession: MultiTrackSessionFile
            do {
                decodedSession = try JSONDecoder().decode(MultiTrackSessionFile.self, from: data)
            } catch {
                throw AudioHostError("Failed to read the multi-track session file: \(error.localizedDescription)")
            }
            try decodedSession.validateFormatVersion()
            return (
                decodedSession,
                try SAHManagedSessionStore.managedSessions()
            )
        }.value

        sessionDeviceResolutionAlert = nil
        applySession(session, sourceURL: url)
        recordLastSavedSessionURL(url)
        managedSessions = sessions
    }

    func refreshManagedSessions() throws {
        managedSessions = try SAHManagedSessionStore.managedSessions()
    }

    func setLoadsSavedSessionOnStartup(_ isEnabled: Bool) {
        loadsSavedSessionOnStartup = isEnabled
        persistStartupPreferences()
    }

    func setLaunchesIntoPerformViewOnStartup(_ isEnabled: Bool) {
        launchesIntoPerformViewOnStartup = isEnabled
        persistStartupPreferences()
    }

    func setStartsEngineOnLaunch(_ isEnabled: Bool) {
        startsEngineOnLaunch = isEnabled
        persistStartupPreferences()
    }

    func setStartupSavedSessionSelection(_ selection: StartupSavedSessionSelection) {
        startupSavedSessionSelection = selection
        persistStartupPreferences()
    }

    func setStartupSpecificSessionURL(_ url: URL?) {
        startupSpecificSessionURL = url
        if url != nil {
            startupSavedSessionSelection = .specific
        }
        persistStartupPreferences()
    }

    func setOpensStartupSpecificSessionAsTemplate(_ isEnabled: Bool) {
        opensStartupSpecificSessionAsTemplate = isEnabled
        persistStartupPreferences()
    }

    func managedSessionsDirectoryURL() throws -> URL {
        try SAHManagedSessionStore.sessionsDirectoryURL()
    }

    func chainPresetsDirectoryURL() throws -> URL {
        try SAHManagedSessionStore.chainPresetsDirectoryURL()
    }

    func parameterPresetsDirectoryURL() throws -> URL {
        try SAHManagedSessionStore.parameterPresetsDirectoryURL()
    }

    func suggestedChainPresetFilename(for trackID: UUID) -> String {
        guard let track = tracks.first(where: { $0.id == trackID }) else {
            return sanitizedFilename(from: "Chain Preset", pathExtension: "sahchain")
        }
        return sanitizedFilename(from: "\(track.name) Chain", pathExtension: "sahchain")
    }

    func suggestedParameterPresetFilename(for trackID: UUID) -> String {
        guard let track = tracks.first(where: { $0.id == trackID }) else {
            return sanitizedFilename(from: "Parameter Preset", pathExtension: "sahparams")
        }
        return sanitizedFilename(from: "\(track.name) Parameters", pathExtension: "sahparams")
    }

    func saveChainPreset(for trackID: UUID, to url: URL) throws {
        if isRunning {
            captureLivePluginStates()
        }
        guard let track = tracks.first(where: { $0.id == trackID }) else {
            throw AudioHostError("The selected track could not be found.")
        }

        let preset = MultiTrackChainPresetFile(
            name: track.name,
            layout: track.layout,
            plugins: track.plugins
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(preset)
        let resolvedURL = normalizedURL(url, pathExtension: "sahchain")
        try data.write(to: resolvedURL, options: .atomic)
        statusMessage = "Saved chain preset \(resolvedURL.deletingPathExtension().lastPathComponent)."
    }

    func loadChainPreset(for trackID: UUID, from url: URL) throws {
        let data = try Data(contentsOf: url)
        let preset: MultiTrackChainPresetFile
        do {
            preset = try JSONDecoder().decode(MultiTrackChainPresetFile.self, from: data)
        } catch {
            throw AudioHostError("Failed to read the chain preset file: \(error.localizedDescription)")
        }
        try preset.validateFormatVersion()

        guard let trackIndex = tracks.firstIndex(where: { $0.id == trackID }) else {
            throw AudioHostError("The selected track could not be found.")
        }

        guard tracks[trackIndex].layout == preset.layout else {
            throw AudioHostError(
                "\(tracks[trackIndex].name) is \(tracks[trackIndex].layout.title.lowercased()), " +
                "but this chain preset requires \(preset.layout.title.lowercased())."
            )
        }

        tracks[trackIndex].plugins = preset.plugins.map { insert in
            MultiTrackTrackConfiguration.PluginInsert(
                pluginID: insert.pluginID,
                pluginStateData: insert.pluginStateData
            )
        }
        updateSessionWarnings()
        statusMessage = "Loaded chain preset \(url.deletingPathExtension().lastPathComponent) into \(tracks[trackIndex].name)."
    }

    func saveParameterPreset(for trackID: UUID, to url: URL) throws {
        if isRunning {
            captureLivePluginStates()
        }
        guard let track = tracks.first(where: { $0.id == trackID }) else {
            throw AudioHostError("The selected track could not be found.")
        }

        let pluginStates = track.plugins.compactMap { insert in
            insert.pluginID.map { pluginID in
                MultiTrackParameterPresetPluginState(
                    pluginID: pluginID,
                    pluginStateData: insert.pluginStateData
                )
            }
        }

        guard !pluginStates.isEmpty else {
            throw AudioHostError("Add at least one plugin before saving a parameter preset.")
        }

        let preset = MultiTrackParameterPresetFile(
            name: track.name,
            plugins: pluginStates
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(preset)
        let resolvedURL = normalizedURL(url, pathExtension: "sahparams")
        try data.write(to: resolvedURL, options: .atomic)
        statusMessage = "Saved parameter preset \(resolvedURL.deletingPathExtension().lastPathComponent)."
    }

    func loadParameterPreset(for trackID: UUID, from url: URL) throws {
        let data = try Data(contentsOf: url)
        let preset: MultiTrackParameterPresetFile
        do {
            preset = try JSONDecoder().decode(MultiTrackParameterPresetFile.self, from: data)
        } catch {
            throw AudioHostError("Failed to read the parameter preset file: \(error.localizedDescription)")
        }
        try preset.validateFormatVersion()

        guard let trackIndex = tracks.firstIndex(where: { $0.id == trackID }) else {
            throw AudioHostError("The selected track could not be found.")
        }

        let pluginIndices = tracks[trackIndex].plugins.indices.filter { index in
            tracks[trackIndex].plugins[index].pluginID != nil
        }
        let currentPluginIDs = pluginIndices.compactMap { index in
            tracks[trackIndex].plugins[index].pluginID
        }
        let presetPluginIDs = preset.plugins.map(\.pluginID)

        guard currentPluginIDs == presetPluginIDs else {
            throw AudioHostError("Parameter presets require the exact same plugin chain in the same order.")
        }

        var failedPluginNames: [String] = []
        if isRunning {
            let stateMap = Dictionary(uniqueKeysWithValues: zip(pluginIndices, preset.plugins).compactMap { index, pluginState in
                pluginState.pluginStateData.map { data in
                    (tracks[trackIndex].plugins[index].id, data)
                }
            })
            let failures = try controller.applyPluginStates(
                for: tracks[trackIndex].id,
                statesByInsertID: stateMap
            )

            for (position, pluginIndex) in pluginIndices.enumerated() {
                let insertID = tracks[trackIndex].plugins[pluginIndex].id
                if let failedName = failures[insertID] {
                    failedPluginNames.append(failedName)
                    continue
                }
                tracks[trackIndex].plugins[pluginIndex].pluginStateData = preset.plugins[position].pluginStateData
            }
        } else {
            for (position, pluginIndex) in pluginIndices.enumerated() {
                tracks[trackIndex].plugins[pluginIndex].pluginStateData = preset.plugins[position].pluginStateData
            }
        }

        let presetName = url.deletingPathExtension().lastPathComponent
        if failedPluginNames.isEmpty {
            statusMessage = "Loaded parameter preset \(presetName) into \(tracks[trackIndex].name)."
        } else {
            statusMessage = "Loaded parameter preset \(presetName) with failures: \(failedPluginNames.joined(separator: ", "))."
        }
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

    func canPasteTrackProcessing(to trackID: UUID) -> Bool {
        copiedTrackProcessing != nil && !isRunning && tracks.contains(where: { $0.id == trackID })
    }

    func copyTrackProcessing(from trackID: UUID) {
        guard tracks.contains(where: { $0.id == trackID }) else { return }

        if isRunning {
            captureLivePluginStates()
        }

        guard let refreshedTrack = tracks.first(where: { $0.id == trackID }) else { return }
        copiedTrackProcessing = CopiedTrackProcessing(
            sourceTrackName: refreshedTrack.name,
            inserts: refreshedTrack.plugins
        )
        statusMessage = refreshedTrack.plugins.isEmpty
            ? "Copied empty processing from \(refreshedTrack.name)."
            : "Copied processing from \(refreshedTrack.name)."
    }

    func pasteTrackProcessing(to trackID: UUID) {
        guard !isRunning else {
            statusMessage = "Stop the engine before pasting track processing."
            return
        }
        guard let copiedTrackProcessing else {
            statusMessage = "Copy a track’s processing first."
            return
        }
        guard let trackIndex = tracks.firstIndex(where: { $0.id == trackID }) else { return }

        tracks[trackIndex].plugins = copiedTrackProcessing.inserts.map { insert in
            MultiTrackTrackConfiguration.PluginInsert(
                pluginID: insert.pluginID,
                pluginStateData: insert.pluginStateData
            )
        }
        updateSessionWarnings()
        statusMessage = "Pasted processing from \(copiedTrackProcessing.sourceTrackName) to \(tracks[trackIndex].name)."
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

    func setWavesTuneEnabled(_ isEnabled: Bool) {
        wavesTuneState.isEnabled = isEnabled

        guard isRunning else {
            statusMessage = configuredWavesTuneRealtimeInsertCount > 0
                ? "Waves Tune will start \(isEnabled ? "enabled" : "bypassed")."
                : "No Waves Tune Real-Time inserts are configured."
            return
        }

        do {
            let affectedInstances = try controller.setWavesTuneRealtimeBypassed(!isEnabled)
            statusMessage = affectedInstances > 0
                ? "Set Waves Tune \(isEnabled ? "active" : "bypassed") on \(affectedInstances) instance(s)."
                : "No running Waves Tune Real-Time instances were found."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func setWavesTuneStrength(_ strength: WavesTuneStrengthPreset, for trackID: UUID) {
        guard let trackIndex = tracks.firstIndex(where: { $0.id == trackID }) else { return }
        let track = tracks[trackIndex]
        guard track.wavesTuneStrength != strength else { return }

        tracks[trackIndex].wavesTuneStrength = strength

        guard strength != .custom else {
            statusMessage = isRunning
                ? "Left \(tracks[trackIndex].name) on its current Waves Tune settings."
                : "\(tracks[trackIndex].name) will keep its current Waves Tune settings."
            return
        }

        guard isRunning else {
            statusMessage = trackHasConfiguredWavesTuneRealtimeInsert(tracks[trackIndex])
                ? "\(tracks[trackIndex].name) tune strength saved as \(strength.title)."
                : "\(tracks[trackIndex].name) does not have Waves Tune Real-Time loaded."
            return
        }

        guard tracks[trackIndex].isEnabled else {
            statusMessage = "\(tracks[trackIndex].name) is disabled. \(strength.title) will apply when the track is enabled and started."
            return
        }

        do {
            let affectedInstances = try controller.applyWavesTuneRealtimeStrength(strength, to: trackID)
            refreshWavesTuneStrengthSelectionFromRunningEngine(for: trackID)
            statusMessage = affectedInstances > 0
                ? "Set \(tracks[trackIndex].name) to \(tracks[trackIndex].wavesTuneStrength.title) tune strength."
                : "No running Waves Tune Real-Time instances were found on \(tracks[trackIndex].name)."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func setWavesTuneScaleMode(_ scaleMode: WavesTuneScaleMode) {
        wavesTuneState.stagedKey.scaleMode = scaleMode
    }

    func setWavesTuneNoteLetter(_ noteLetter: WavesTuneNoteLetter) {
        wavesTuneState.stagedKey.noteLetter = noteLetter
        wavesTuneState.stagedKey.normalize()
    }

    func setWavesTuneAccidental(_ accidental: WavesTuneAccidental) {
        guard WavesTuneKeySelection.supports(accidental: accidental, for: wavesTuneState.stagedKey.noteLetter) else {
            return
        }
        wavesTuneState.stagedKey.accidental = accidental
    }

    func addWavesTuneSong(title: String, key: WavesTuneKeySelection) {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            statusMessage = "Enter a song name."
            return
        }

        let song = WavesTuneSongEntry(
            title: trimmedTitle,
            key: key.normalized
        )
        wavesTuneState.songs.append(song)
        activateWavesTuneSong(at: wavesTuneState.songs.count - 1, action: "Added")
    }

    func removeWavesTuneSong(_ id: UUID) {
        guard let index = wavesTuneState.songs.firstIndex(where: { $0.id == id }) else { return }
        let removedTitle = wavesTuneSongDisplayTitle(for: wavesTuneState.songs[index], index: index)
        let removedWasSelected = wavesTuneState.selectedSongID == id
        wavesTuneState.songs.remove(at: index)

        guard removedWasSelected else {
            statusMessage = "Removed \(removedTitle)."
            return
        }

        guard !wavesTuneState.songs.isEmpty else {
            wavesTuneState.selectedSongID = nil
            statusMessage = "Removed \(removedTitle)."
            return
        }

        activateWavesTuneSong(at: min(index, wavesTuneState.songs.count - 1), action: "Selected")
    }

    func updateWavesTuneSongTitle(_ id: UUID, title: String) {
        guard let index = wavesTuneState.songs.firstIndex(where: { $0.id == id }) else { return }
        wavesTuneState.songs[index].title = title
    }

    func updateWavesTuneSongNotes(_ id: UUID, notes: String) {
        guard let index = wavesTuneState.songs.firstIndex(where: { $0.id == id }) else { return }
        wavesTuneState.songs[index].notes = notes
    }

    func moveWavesTuneSong(_ id: UUID, direction: Int) {
        guard direction != 0 else { return }
        guard let index = wavesTuneState.songs.firstIndex(where: { $0.id == id }) else { return }
        let targetIndex = index + direction
        guard wavesTuneState.songs.indices.contains(targetIndex) else { return }
        let song = wavesTuneState.songs.remove(at: index)
        wavesTuneState.songs.insert(song, at: targetIndex)
        wavesTuneState.selectedSongID = song.id
        statusMessage = "Moved \(wavesTuneSongDisplayTitle(for: song, index: targetIndex))."
    }

    func duplicateWavesTuneSong(_ id: UUID) {
        guard let index = wavesTuneState.songs.firstIndex(where: { $0.id == id }) else { return }
        let source = wavesTuneState.songs[index]
        let duplicate = WavesTuneSongEntry(
            title: "\(source.title) Copy",
            key: source.key.normalized,
            notes: source.notes
        )
        let targetIndex = index + 1
        wavesTuneState.songs.insert(duplicate, at: targetIndex)
        activateWavesTuneSong(at: targetIndex, action: "Duplicated")
    }

    func selectWavesTuneSong(_ id: UUID) {
        guard let index = wavesTuneState.songs.firstIndex(where: { $0.id == id }) else { return }
        activateWavesTuneSong(at: index, action: "Selected")
    }

    func stepWavesTuneSong(direction: Int) {
        guard direction != 0, !wavesTuneState.songs.isEmpty else { return }

        let targetIndex: Int
        if let selectedWavesTuneSongIndex {
            let nextIndex = selectedWavesTuneSongIndex + direction
            guard wavesTuneState.songs.indices.contains(nextIndex) else { return }
            targetIndex = nextIndex
        } else if direction > 0 {
            targetIndex = 0
        } else {
            targetIndex = wavesTuneState.songs.count - 1
        }

        activateWavesTuneSong(at: targetIndex, action: "Selected")
    }

    func triggerWavesTuneKeyPanic() {
        var chromaticSelection = wavesTuneState.appliedKey.normalized
        chromaticSelection.scaleMode = .chromatic
        setActiveWavesTuneKey(
            chromaticSelection,
            offlineMessage: "Key Panic armed. Start the engine to apply Chromatic.",
            onlineMessage: { affectedInstances in
                "Key Panic applied Chromatic to \(affectedInstances) instance(s)."
            }
        )
    }

    func saveStagedKeyToSelectedWavesTuneSong() {
        guard let selectedWavesTuneSongIndex else {
            statusMessage = "Select a song first."
            return
        }

        let normalizedKey = wavesTuneState.stagedKey.normalized
        wavesTuneState.songs[selectedWavesTuneSongIndex].key = normalizedKey
        activateWavesTuneSong(at: selectedWavesTuneSongIndex, action: "Saved")
    }

    func applyStagedWavesTuneKey() {
        let normalizedKey = wavesTuneState.stagedKey.normalized
        setActiveWavesTuneKey(
            normalizedKey,
            offlineMessage: "Saved Waves Tune key \(normalizedKey.title). Start the engine to apply it.",
            onlineMessage: { affectedInstances in
                "Applied Waves Tune key \(normalizedKey.title) to \(affectedInstances) instance(s)."
            }
        )
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

    private func startEngine() {
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
                _ = try self.controller.setWavesTuneRealtimeBypassed(!self.wavesTuneState.isEnabled)
                _ = try self.controller.applyWavesTuneRealtimeKeySelection(self.wavesTuneState.appliedKey.normalized)
                self.syncWavesTuneStrengthSelectionsFromRunningEngine()
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
        clearEmbeddedPluginEditor()
        audioDropoutMonitorTask?.cancel()
        audioDropoutMonitorTask = nil
        startupDropoutResetTask?.cancel()
        startupDropoutResetTask = nil
        refreshPublishedTelemetry()
        captureLivePluginStates()
        controller.stop()
        isRunning = false
        trackPluginLatencyFrames = [:]
        statusMessage = "Stopped."
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

    private func applySession(_ session: MultiTrackSessionFile, sourceURL: URL?) {
        isApplyingSessionState = true
        sessionReloadRetryContext = sourceURL.map { SessionReloadRetryContext(sessionURL: $0, reopensAsTemplate: false) }
        selectedInputDeviceID = resolvedSessionDeviceID(
            preferredUID: session.inputDeviceUID,
            availableDevices: inputDevices
        )
        if selectedInputDeviceID == nil {
            selectedInputDeviceID = resolvedSessionDeviceID(
                preferredUID: session.outputDeviceUID,
                availableDevices: inputDevices
            )
        }
        selectedOutputDeviceID = selectedInputDeviceID
        selectedBufferSize = session.bufferSize
        customBufferSizeText = String(session.bufferSize)
        latencyBufferSettings = session.latencyBufferSettings
        sanitizeLatencyBufferSettings()
        tracks = session.tracks.isEmpty
            ? [MultiTrackTrackConfiguration(name: "Track 1", layout: .mono)]
            : session.tracks

        currentSessionURL = sourceURL
        currentSessionName = sourceURL.map(sessionDisplayName(for:)) ?? session.name
        wavesTuneState = session.wavesTuneState ?? MultiTrackWavesTuneState()
        wavesTuneState.normalize()

        sanitizeTracks(clampTrackRouting: false)
        updateSessionWarnings()

        isApplyingSessionState = false
        hasUnsavedChanges = false
        statusMessage = "Loaded \(currentSessionName)."
    }

    private func sanitizeTracks(clampTrackRouting: Bool = true) {
        if clampTrackRouting {
            for index in tracks.indices {
                tracks[index] = sanitizedTrack(tracks[index])
            }
        }
        if tracks.isEmpty {
            tracks = [MultiTrackTrackConfiguration(name: "Track 1", layout: .mono)]
        }
        if let preferredBufferSize = DefaultBufferSizes.preferredHardwareBufferSize(from: availableBufferSizes), !isSelectedBufferSizeValid {
            selectedBufferSize = preferredBufferSize
        }
        customBufferSizeText = String(selectedBufferSize)
        updateSessionWarnings()
    }

    private func resolvedSessionDeviceID(
        preferredUID: String?,
        availableDevices: [AudioDeviceInfo]
    ) -> AudioDeviceID? {
        if let preferredUID,
           let matchedDeviceID = availableDevices.first(where: { $0.uid == preferredUID })?.id {
            return matchedDeviceID
        }

        return nil
    }

    private func sanitizeLatencyBufferSettings() {
        latencyBufferSettings.bufferedFrames = normalizedInternalBufferSize(latencyBufferSettings.bufferedFrames)
        latencyBufferSettings.broadcastFrames = normalizedInternalBufferSize(latencyBufferSettings.broadcastFrames)
        latencyBufferSettings.broadcastPrerollMultiplier = normalizedBroadcastPrerollMultiplier(
            latencyBufferSettings.broadcastPrerollMultiplier
        )
        bufferedInternalBufferText = String(latencyBufferSettings.bufferedFrames)
        broadcastInternalBufferText = String(latencyBufferSettings.broadcastFrames)
        broadcastPrerollMultiplier = latencyBufferSettings.broadcastPrerollMultiplier
    }

    private func normalizedBroadcastPrerollMultiplier(_ value: Int) -> Int {
        min(max(value, 1), 3)
    }

    private func updateSessionWarnings() {
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

        for insert in track.plugins {
            if let pluginID = insert.pluginID, !plugins.contains(where: { $0.id == pluginID }) {
                return "\(track.name) references a plugin that is not currently installed. Install it or choose Bypass."
            }
        }

        return nil
    }

    private func validateExclusiveOutputRouting(
        for tracks: [MultiTrackTrackConfiguration]
    ) -> String? {
        var channelOwners: [Int: String] = [:]

        for track in tracks where track.isEnabled {
            let outputChannels = track.outputStartChannel..<(track.outputStartChannel + track.channelCount)
            for channel in outputChannels {
                if let existingOwner = channelOwners[channel] {
                    return "\(track.name) conflicts with \(existingOwner) on output channel \(channel). Outputs are exclusive."
                }
                channelOwners[channel] = track.name
            }
        }

        return nil
    }

    private func outputChannelsAreAvailable(
        for track: MultiTrackTrackConfiguration,
        proposedStartChannel: Int
    ) -> Bool {
        let proposedRange = proposedStartChannel..<(proposedStartChannel + track.channelCount)

        for otherTrack in tracks where otherTrack.id != track.id && otherTrack.isEnabled {
            let otherRange = otherTrack.outputStartChannel..<(otherTrack.outputStartChannel + otherTrack.channelCount)
            if proposedRange.overlaps(otherRange) {
                return false
            }
        }

        return true
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

    private func makeSessionFile() -> MultiTrackSessionFile {
        captureLivePluginStates()
        return MultiTrackSessionFile(
            name: currentSessionURL.map(sessionDisplayName(for:)) ?? currentSessionName,
            inputDeviceUID: selectedInputDevice?.uid,
            outputDeviceUID: selectedOutputDevice?.uid,
            bufferSize: selectedBufferSize,
            latencyBufferSettings: latencyBufferSettings,
            tracks: tracks,
            wavesTuneState: wavesTuneState.normalized
        )
    }

    private func captureLivePluginStates() {
        guard isRunning else { return }
        let pluginStates = controller.pluginStateSnapshot()
        guard !pluginStates.isEmpty else { return }
        for index in tracks.indices {
            let trackID = tracks[index].id
            guard let pluginStateMap = pluginStates[trackID] else { continue }
            for pluginIndex in tracks[index].plugins.indices {
                let pluginID = tracks[index].plugins[pluginIndex].id
                if let pluginState = pluginStateMap[pluginID] {
                    tracks[index].plugins[pluginIndex].pluginStateData = pluginState
                }
            }
        }
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

    func companionControlStateSnapshot() -> CompanionControlStateSnapshot {
        CompanionControlStateSnapshot(
            apiVersion: 1,
            appMode: "multiTrack",
            timestamp: Self.iso8601Formatter.string(from: Date()),
            sessionName: currentSessionDisplayName,
            statusMessage: statusMessage,
            isRunning: isRunning,
            wavesTune: CompanionControlWavesTuneSnapshot(
                isEnabled: wavesTuneState.isEnabled,
                configuredInsertCount: configuredWavesTuneRealtimeInsertCount,
                canApplyStagedKey: canApplyStagedWavesTuneKey,
                stagedKey: CompanionControlKeySnapshot(selection: wavesTuneState.stagedKey),
                appliedKey: CompanionControlKeySnapshot(selection: wavesTuneState.appliedKey),
                selectedSongTitle: selectedWavesTuneSongIndex.map {
                    wavesTuneSongDisplayTitle(for: wavesTuneState.songs[$0], index: $0)
                },
                selectedSongIndex: selectedWavesTuneSongIndex,
                songCount: wavesTuneState.songs.count,
                previousSongKey: previousWavesTuneSongIndex.map {
                    CompanionControlKeySnapshot(selection: wavesTuneState.songs[$0].key)
                },
                nextSongKey: nextWavesTuneSongIndex.map {
                    CompanionControlKeySnapshot(selection: wavesTuneState.songs[$0].key)
                },
                canSelectPreviousSong: canSelectPreviousWavesTuneSong,
                canSelectNextSong: canSelectNextWavesTuneSong
            )
        )
    }

    func companionControlHTTPResponse(for request: CompanionControlHTTPRequest) -> CompanionControlHTTPResponse {
        if let validationResponse = companionControlValidationErrorHTTPResponse(for: request) {
            return validationResponse
        }

        switch (request.method, request.path) {
        case ("GET", "/health"), ("GET", "/api/v1/health"):
            return .json(
                statusCode: 200,
                value: CompanionControlHealthResponse(
                    ok: true,
                    apiVersion: 1,
                    appMode: "multiTrack"
                )
            )

        case ("GET", "/api/v1/state"):
            return .json(statusCode: 200, value: companionControlStateSnapshot())

        case ("POST", "/api/v1/actions/waves-tune/enabled"):
            do {
                let payload = try decodeCompanionControlRequest(CompanionControlSetEnabledRequest.self, from: request.body)
                setWavesTuneEnabled(payload.enabled)
                return companionControlCommandHTTPResponse()
            } catch {
                return companionControlErrorHTTPResponse(statusCode: 400, message: error.localizedDescription)
            }

        case ("POST", "/api/v1/actions/waves-tune/toggle-enabled"):
            setWavesTuneEnabled(!wavesTuneState.isEnabled)
            return companionControlCommandHTTPResponse()

        case ("POST", "/api/v1/actions/waves-tune/staged-key"):
            do {
                let payload = try decodeCompanionControlRequest(CompanionControlSetStagedKeyRequest.self, from: request.body)
                try setCompanionControlStagedWavesTuneKey(root: payload.root, scaleMode: payload.scaleMode)
                return companionControlCommandHTTPResponse()
            } catch {
                return companionControlErrorHTTPResponse(statusCode: 400, message: error.localizedDescription)
            }

        case ("POST", "/api/v1/actions/waves-tune/scale-mode"):
            do {
                let payload = try decodeCompanionControlRequest(CompanionControlSetScaleModeRequest.self, from: request.body)
                try setCompanionControlWavesTuneScaleMode(payload.scaleMode)
                return companionControlCommandHTTPResponse()
            } catch {
                return companionControlErrorHTTPResponse(statusCode: 400, message: error.localizedDescription)
            }

        case ("POST", "/api/v1/actions/waves-tune/note-letter"):
            do {
                let payload = try decodeCompanionControlRequest(CompanionControlSetNoteLetterRequest.self, from: request.body)
                try setCompanionControlWavesTuneNoteLetter(payload.noteLetter)
                return companionControlCommandHTTPResponse()
            } catch {
                return companionControlErrorHTTPResponse(statusCode: 400, message: error.localizedDescription)
            }

        case ("POST", "/api/v1/actions/waves-tune/accidental"):
            do {
                let payload = try decodeCompanionControlRequest(CompanionControlSetAccidentalRequest.self, from: request.body)
                try setCompanionControlWavesTuneAccidental(payload.accidental)
                return companionControlCommandHTTPResponse()
            } catch {
                return companionControlErrorHTTPResponse(statusCode: 400, message: error.localizedDescription)
            }

        case ("POST", "/api/v1/actions/waves-tune/apply"):
            applyStagedWavesTuneKey()
            return companionControlCommandHTTPResponse()

        case ("POST", "/api/v1/actions/waves-tune/panic"):
            triggerWavesTuneKeyPanic()
            return companionControlCommandHTTPResponse()

        case ("POST", "/api/v1/actions/waves-tune/step-song"):
            do {
                let payload = try decodeCompanionControlRequest(CompanionControlStepSongRequest.self, from: request.body)
                guard payload.direction == -1 || payload.direction == 1 else {
                    throw AudioHostError("Song step direction must be -1 or 1.")
                }
                stepWavesTuneSong(direction: payload.direction)
                return companionControlCommandHTTPResponse()
            } catch {
                return companionControlErrorHTTPResponse(statusCode: 400, message: error.localizedDescription)
            }

        case ("GET", _), ("POST", _):
            return companionControlErrorHTTPResponse(statusCode: 404, message: "No Companion control route matches \(request.path).")

        default:
            return companionControlErrorHTTPResponse(statusCode: 405, message: "Use GET or POST with the Companion control API.")
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
                        controller.stop()
                        self.isRunning = false
                        self.trackPluginLatencyFrames = [:]
                        self.statusMessage = runtimeStatus
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

    private func refreshPublishedTelemetry() {
        refreshTrackPluginLatencyFrames()
        applyTelemetrySnapshot(
            dropoutCount: controller.audioDropoutCount(),
            droppedFrameCount: controller.droppedFrameCount(),
            telemetry: controller.telemetrySnapshot()
        )
    }

    private func refreshTrackPluginLatencyFrames() {
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

    private func applyTelemetrySnapshot(
        dropoutCount: UInt64,
        droppedFrameCount: UInt64,
        telemetry: AudioEngineTelemetrySnapshot
    ) {
        audioDropoutCount = dropoutCount
        self.droppedFrameCount = droppedFrameCount
        telemetrySummary = "Callbacks in/out: \(telemetry.peakInputCallbackFrames) / \(telemetry.peakOutputCallbackFrames) frames"
        ringTelemetrySummary = "Peak ring occupancy in/out: \(telemetryOccupancyString(telemetry.peakInputRingOccupancyFrames, capacity: telemetry.inputRingCapacityFrames)) / \(telemetryOccupancyString(telemetry.peakOutputRingOccupancyFrames, capacity: telemetry.outputRingCapacityFrames))"
        workerTelemetrySummary = "Workers: \(telemetry.workerShardCount) shards, track/shard render avg \(telemetry.averageTrackRenderDurationMicros) / \(telemetry.averageShardRenderDurationMicros) us, peak \(telemetry.peakTrackRenderDurationMicros) / \(telemetry.peakShardRenderDurationMicros) us, util \(telemetry.peakShardUtilizationPercent)%, wakeups \(telemetry.peakWorkerWakeupsPerSecond)/s"
        realtimeTelemetrySummary = realtimeTelemetryString(telemetry.realtime)
        bufferedTelemetrySummary = bufferedTelemetryString(label: "Buffered", telemetry.buffered)
        broadcastTelemetrySummary = bufferedTelemetryString(label: "Broadcast", telemetry.broadcast)
    }

    private func realtimeTelemetryString(_ telemetry: LatencyClassTelemetrySnapshot) -> String {
        "Realtime: \(telemetry.trackCount) tracks, render avg/peak \(telemetry.averageTrackRenderDurationMicros) / \(telemetry.peakTrackRenderDurationMicros) us"
    }

    private func bufferedTelemetryString(
        label: String,
        _ telemetry: LatencyClassTelemetrySnapshot
    ) -> String {
        "\(label): \(telemetry.trackCount) tracks, \(telemetry.workerShardCount) shards, track/shard avg \(telemetry.averageTrackRenderDurationMicros) / \(telemetry.averageShardRenderDurationMicros) us, peak \(telemetry.peakTrackRenderDurationMicros) / \(telemetry.peakShardRenderDurationMicros) us, util \(telemetry.peakShardUtilizationPercent)%, wakeups \(telemetry.peakWorkerWakeupsPerSecond)/s"
    }

    private func telemetryOccupancyString(_ frames: UInt64, capacity: Int) -> String {
        guard capacity > 0 else {
            return "\(frames) frames"
        }
        let percent = Double(frames) / Double(capacity) * 100
        return "\(frames) frames (\(Int(percent.rounded()))%)"
    }

    private func updateSessionNameIfNeeded() {
        if let currentSessionURL {
            currentSessionName = sessionDisplayName(for: currentSessionURL)
        }
    }

    private func setupSessionChangeObservers() {
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

        $wavesTuneState
            .dropFirst()
            .sink { [weak self] _ in
                self?.markSessionAsEdited()
            }
            .store(in: &persistenceCancellables)
    }

    private func markSessionAsEdited() {
        guard !isApplyingSessionState else { return }
        hasUnsavedChanges = true
    }

    private func openCurrentSessionAsTemplate() {
        currentSessionURL = nil
        isCurrentSessionStartupTemplate = true
        if let retryContext = sessionReloadRetryContext {
            sessionReloadRetryContext = SessionReloadRetryContext(
                sessionURL: retryContext.sessionURL,
                reopensAsTemplate: true
            )
        }
        hasUnsavedChanges = false
        statusMessage = "Loaded \(currentSessionName) as a startup template."
    }

    private func presentSessionDeviceResolutionAlertIfNeeded() -> Bool {
        guard sessionReloadRetryContext != nil else { return false }

        var unavailableDevices: [String] = []
        if selectedInputDevice == nil {
            unavailableDevices.append("input")
        }
        if selectedOutputDevice == nil {
            unavailableDevices.append("output")
        }

        guard !unavailableDevices.isEmpty else { return false }

        let deviceSummary = unavailableDevices.joined(separator: " and ")
        let message = "The saved session could not resolve its \(deviceSummary) device. Reconnect the interface, then retry to rescan devices and reload the session."
        sessionDeviceResolutionAlert = SessionDeviceResolutionAlert(message: message)
        statusMessage = message
        return true
    }

    private func sessionDisplayName(for url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }

    private func sanitizedSessionFilename(from name: String) -> String {
        sanitizedFilename(from: name, pathExtension: "sahsession")
    }

    private func sanitizedFilename(from name: String, pathExtension: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseName = trimmed.isEmpty ? "MultiTrack Session" : trimmed
        let invalidCharacters = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let cleaned = String(baseName.unicodeScalars.map { invalidCharacters.contains($0) ? "-" : Character($0) })
        let dottedExtension = ".\(pathExtension)"
        return cleaned.hasSuffix(dottedExtension) ? cleaned : "\(cleaned)\(dottedExtension)"
    }

    private func normalizedURL(_ url: URL, pathExtension: String) -> URL {
        if url.pathExtension.caseInsensitiveCompare(pathExtension) == .orderedSame {
            return url
        }
        return url.appendingPathExtension(pathExtension)
    }

    private func loadPersistedStartupPreferences() {
        launchesIntoPerformViewOnStartup = userDefaults.bool(forKey: Self.launchesIntoPerformViewOnStartupKey)
        loadsSavedSessionOnStartup = userDefaults.bool(forKey: Self.loadsSavedSessionOnStartupKey)
        startsEngineOnLaunch = userDefaults.bool(forKey: Self.startsEngineOnLaunchKey)

        if let rawValue = userDefaults.string(forKey: Self.startupSavedSessionSelectionKey),
           let selection = StartupSavedSessionSelection(rawValue: rawValue) {
            startupSavedSessionSelection = selection
        }

        startupSpecificSessionURL = Self.fileURL(fromStoredPath: userDefaults.string(forKey: Self.startupSpecificSessionPathKey))
        opensStartupSpecificSessionAsTemplate = userDefaults.bool(forKey: Self.opensStartupSpecificSessionAsTemplateKey)
        lastSavedSessionURL = Self.fileURL(fromStoredPath: userDefaults.string(forKey: Self.lastSavedSessionPathKey))
    }

    private func persistStartupPreferences() {
        userDefaults.set(launchesIntoPerformViewOnStartup, forKey: Self.launchesIntoPerformViewOnStartupKey)
        userDefaults.set(loadsSavedSessionOnStartup, forKey: Self.loadsSavedSessionOnStartupKey)
        userDefaults.set(startsEngineOnLaunch, forKey: Self.startsEngineOnLaunchKey)
        userDefaults.set(startupSavedSessionSelection.rawValue, forKey: Self.startupSavedSessionSelectionKey)

        if let startupSpecificSessionURL {
            userDefaults.set(startupSpecificSessionURL.path, forKey: Self.startupSpecificSessionPathKey)
        } else {
            userDefaults.removeObject(forKey: Self.startupSpecificSessionPathKey)
        }

        userDefaults.set(opensStartupSpecificSessionAsTemplate, forKey: Self.opensStartupSpecificSessionAsTemplateKey)
    }

    private func recordLastSavedSessionURL(_ url: URL) {
        lastSavedSessionURL = url
        userDefaults.set(url.path, forKey: Self.lastSavedSessionPathKey)
    }

    private func startCompanionControlServer() {
        do {
            try companionControlServer.start(
                requestHandler: { [weak self] request in
                    guard let self else {
                        return CompanionControlHTTPResponse.json(
                            statusCode: 503,
                            value: CompanionControlBasicErrorResponse(
                                ok: false,
                                message: "The multi-track controller is unavailable."
                            )
                        )
                    }
                    return await self.companionControlHTTPResponse(for: request)
                },
                stateHandler: { [weak self] state in
                    Task { @MainActor [weak self] in
                        self?.applyCompanionControlServerLifecycleState(state)
                    }
                }
            )
        } catch {
            companionControlStatus = "Companion control API failed to start: \(error.localizedDescription)"
        }
    }

    private func applyCompanionControlServerLifecycleState(_ state: CompanionControlServerLifecycleState) {
        switch state {
        case .starting(let url):
            companionControlEndpointURLString = url
            companionControlStatus = "Starting local Companion control API..."
        case .listening(let url):
            companionControlEndpointURLString = url
            companionControlStatus = "Listening on \(url)"
        case .failed(let message):
            companionControlStatus = "Companion control API error: \(message)"
        case .stopped:
            companionControlStatus = "Companion control API stopped."
        }
    }

    private func companionControlCommandHTTPResponse() -> CompanionControlHTTPResponse {
        .json(
            statusCode: 200,
            value: CompanionControlCommandResponse(
                ok: true,
                message: statusMessage,
                state: companionControlStateSnapshot()
            )
        )
    }

    private func companionControlErrorHTTPResponse(
        statusCode: Int,
        message: String
    ) -> CompanionControlHTTPResponse {
        .json(
            statusCode: statusCode,
            value: CompanionControlCommandResponse(
                ok: false,
                message: message,
                state: companionControlStateSnapshot()
            )
        )
    }

    private func companionControlValidationErrorHTTPResponse(
        for request: CompanionControlHTTPRequest
    ) -> CompanionControlHTTPResponse? {
        if let host = request.headers["host"]?.lowercased(),
           !CompanionControlDefaults.allowedHostHeaderValues.contains(host) {
            return companionControlErrorHTTPResponse(
                statusCode: 400,
                message: "Invalid Host header."
            )
        }

        guard request.method == "POST" else {
            return nil
        }

        let contentType = request.headers["content-type"]?.lowercased() ?? ""
        guard contentType.hasPrefix("application/json") else {
            return companionControlErrorHTTPResponse(
                statusCode: 415,
                message: "Use Content-Type: application/json."
            )
        }

        return nil
    }

    private func decodeCompanionControlRequest<T: Decodable>(
        _ type: T.Type,
        from body: Data
    ) throws -> T {
        guard !body.isEmpty else {
            throw AudioHostError("This Companion control action requires a JSON body.")
        }

        do {
            return try JSONDecoder().decode(type, from: body)
        } catch {
            throw AudioHostError("Failed to decode the Companion control request.")
        }
    }

    private func setCompanionControlStagedWavesTuneKey(
        root: String,
        scaleMode: String
    ) throws {
        guard let rootChoice = CompanionControlRootChoice(rawValue: root.lowercased()) else {
            throw AudioHostError("Unsupported Waves Tune root: \(root).")
        }
        guard let scaleMode = WavesTuneScaleMode(rawValue: scaleMode.lowercased()) else {
            throw AudioHostError("Unsupported Waves Tune scale mode: \(scaleMode).")
        }

        wavesTuneState.stagedKey = WavesTuneKeySelection(
            scaleMode: scaleMode,
            noteLetter: rootChoice.noteLetter,
            accidental: rootChoice.accidental
        ).normalized
        statusMessage = "Staged Waves Tune key \(wavesTuneState.stagedKey.title)."
    }

    private func setCompanionControlWavesTuneScaleMode(_ scaleMode: String) throws {
        guard let scaleMode = WavesTuneScaleMode(rawValue: scaleMode.lowercased()) else {
            throw AudioHostError("Unsupported Waves Tune scale mode: \(scaleMode).")
        }

        wavesTuneState.stagedKey.scaleMode = scaleMode
        statusMessage = "Staged Waves Tune scale \(wavesTuneState.stagedKey.title)."
    }

    private func setCompanionControlWavesTuneNoteLetter(_ noteLetter: String) throws {
        guard let noteLetter = WavesTuneNoteLetter(rawValue: noteLetter.lowercased()) else {
            throw AudioHostError("Unsupported Waves Tune note letter: \(noteLetter).")
        }

        wavesTuneState.stagedKey.noteLetter = noteLetter
        wavesTuneState.stagedKey.normalize()
        statusMessage = "Staged Waves Tune root \(wavesTuneState.stagedKey.title)."
    }

    private func setCompanionControlWavesTuneAccidental(_ accidental: String) throws {
        guard let accidental = WavesTuneAccidental(rawValue: accidental.lowercased()) else {
            throw AudioHostError("Unsupported Waves Tune accidental: \(accidental).")
        }
        guard WavesTuneKeySelection.supports(
            accidental: accidental,
            for: wavesTuneState.stagedKey.noteLetter
        ) else {
            throw AudioHostError(
                "\(wavesTuneState.stagedKey.noteLetter.title) does not support \(accidental.title)."
            )
        }

        wavesTuneState.stagedKey.accidental = accidental
        statusMessage = "Staged Waves Tune root \(wavesTuneState.stagedKey.title)."
    }

    private func activateWavesTuneSong(at index: Int, action: String) {
        guard wavesTuneState.songs.indices.contains(index) else { return }

        wavesTuneState.songs[index].key = wavesTuneState.songs[index].key.normalized
        wavesTuneState.selectedSongID = wavesTuneState.songs[index].id

        let song = wavesTuneState.songs[index]
        let songTitle = wavesTuneSongDisplayTitle(for: song, index: index)
        setActiveWavesTuneKey(
            song.key,
            offlineMessage: "\(action) \(songTitle). Start the engine to apply \(song.key.title).",
            onlineMessage: { affectedInstances in
                "\(action) \(songTitle). Applied \(song.key.title) to \(affectedInstances) instance(s)."
            }
        )
    }

    private func setActiveWavesTuneKey(
        _ selection: WavesTuneKeySelection,
        offlineMessage: String,
        onlineMessage: (Int) -> String
    ) {
        let normalizedSelection = selection.normalized
        wavesTuneState.stagedKey = normalizedSelection
        wavesTuneState.appliedKey = normalizedSelection

        guard isRunning else {
            statusMessage = configuredWavesTuneRealtimeInsertCount > 0
                ? offlineMessage
                : "\(offlineMessage) No Waves Tune Real-Time inserts are configured."
            return
        }

        do {
            let affectedInstances = try controller.applyWavesTuneRealtimeKeySelection(normalizedSelection)
            statusMessage = affectedInstances > 0
                ? onlineMessage(affectedInstances)
                : "No running Waves Tune Real-Time instances were found."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func wavesTuneSongDisplayTitle(for song: WavesTuneSongEntry, index: Int) -> String {
        let trimmedTitle = song.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedTitle.isEmpty ? "Song \(index + 1)" : trimmedTitle
    }

    private func isWavesTuneRealtimePlugin(_ plugin: AudioUnitPluginInfo) -> Bool {
        plugin.name.localizedCaseInsensitiveContains("Waves Tune Real-Time")
    }

    private func trackHasConfiguredWavesTuneRealtimeInsert(_ track: MultiTrackTrackConfiguration) -> Bool {
        track.plugins.contains { insert in
            guard let pluginID = insert.pluginID,
                  let plugin = plugins.first(where: { $0.id == pluginID }) else {
                return false
            }
            return isWavesTuneRealtimePlugin(plugin)
        }
    }

    private func syncWavesTuneStrengthSelectionsFromRunningEngine() {
        let existingHasUnsavedChanges = hasUnsavedChanges
        isApplyingSessionState = true
        defer {
            isApplyingSessionState = false
            hasUnsavedChanges = existingHasUnsavedChanges
        }

        for track in tracks where track.isEnabled && trackHasConfiguredWavesTuneRealtimeInsert(track) {
            refreshWavesTuneStrengthSelectionFromRunningEngine(for: track.id)
        }
    }

    private func refreshWavesTuneStrengthSelectionFromRunningEngine(for trackID: UUID) {
        guard let trackIndex = tracks.firstIndex(where: { $0.id == trackID }) else { return }

        do {
            guard let preset = try controller.currentWavesTuneRealtimeStrengthPreset(for: trackID) else { return }
            tracks[trackIndex].wavesTuneStrength = preset
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private static let iso8601Formatter = ISO8601DateFormatter()
    private static let templateDateFormatter: DateFormatter = {
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
    private static let launchesIntoPerformViewOnStartupKey = "startup.launchesIntoPerformViewOnStartup"
    private static let loadsSavedSessionOnStartupKey = "startup.loadsSavedSessionOnStartup"
    private static let startsEngineOnLaunchKey = "startup.startsEngineOnLaunch"
    private static let startupSavedSessionSelectionKey = "startup.savedSessionSelection"
    private static let startupSpecificSessionPathKey = "startup.specificSessionPath"
    private static let opensStartupSpecificSessionAsTemplateKey = "startup.opensSpecificSessionAsTemplate"
    private static let lastSavedSessionPathKey = "startup.lastSavedSessionPath"
    private static let startupDropoutGracePeriod: Duration = .seconds(1)

    private static func fileURL(fromStoredPath path: String?) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: false)
    }
}

private enum CompanionControlRootChoice: String {
    case c
    case cSharp = "c#"
    case dFlat = "db"
    case d
    case dSharp = "d#"
    case eFlat = "eb"
    case e
    case f
    case fSharp = "f#"
    case gFlat = "gb"
    case g
    case gSharp = "g#"
    case aFlat = "ab"
    case a
    case aSharp = "a#"
    case bFlat = "bb"
    case b

    var noteLetter: WavesTuneNoteLetter {
        switch self {
        case .c, .cSharp:
            .c
        case .dFlat, .d, .dSharp:
            .d
        case .eFlat, .e:
            .e
        case .f, .fSharp:
            .f
        case .gFlat, .g, .gSharp:
            .g
        case .aFlat, .a, .aSharp:
            .a
        case .bFlat, .b:
            .b
        }
    }

    var accidental: WavesTuneAccidental {
        switch self {
        case .c, .d, .e, .f, .g, .a, .b:
            .natural
        case .cSharp, .dSharp, .fSharp, .gSharp, .aSharp:
            .sharp
        case .dFlat, .eFlat, .gFlat, .aFlat, .bFlat:
            .flat
        }
    }
}
