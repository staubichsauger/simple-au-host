import AVFoundation
import Combine
import SwiftUI

@MainActor
final class MultiTrackViewModel: ObservableObject {
    private struct CopiedTrackProcessing {
        let sourceTrackName: String
        let inserts: [MultiTrackTrackConfiguration.PluginInsert]
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
    @Published private(set) var currentSessionName = "Untitled Session"
    @Published private(set) var sessionWarnings: [String] = []
    @Published private(set) var managedSessions: [ManagedSessionFile] = []
    @Published private(set) var hasUnsavedChanges = false
    @Published var wavesTuneState = MultiTrackWavesTuneState()

    private let catalog = AudioHostController()
    private let controller = MultiTrackAudioHostController()
    private var latencyBufferSettings = MultiTrackLatencyBufferSettings(hardwareBufferSize: DefaultBufferSizes.hardwareFrames)
    private var audioDropoutMonitorTask: Task<Void, Never>?
    private var currentSessionURL: URL?
    private var telemetryPublishingEnabled = false
    private var copiedTrackProcessing: CopiedTrackProcessing?
    private var persistenceCancellables = Set<AnyCancellable>()
    private var isApplyingSessionState = false

    init() {
        setupSessionChangeObservers()
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

    var hasStoredSessionFile: Bool {
        currentSessionURL != nil
    }

    var currentSessionDisplayName: String {
        currentSessionName + (hasUnsavedChanges ? " *" : "")
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
        do {
            let existingHasUnsavedChanges = hasUnsavedChanges
            isApplyingSessionState = true
            _ = try SAHManagedSessionStore.ensureDirectories()
            let allDevices = try catalog.availableDevices()
            inputDevices = allDevices.filter { $0.inputChannelCount > 0 }
            outputDevices = allDevices.filter { $0.outputChannelCount > 0 }
            plugins = try catalog.availablePlugins()

            if selectedInputDeviceID == nil {
                let defaultInputID = try catalog.defaultInputDeviceID()
                selectedInputDeviceID = inputDevices.first(where: { $0.id == defaultInputID })?.id ?? inputDevices.first?.id
            }
            if selectedOutputDeviceID == nil {
                let defaultOutputID = try catalog.defaultOutputDeviceID()
                selectedOutputDeviceID = outputDevices.first(where: { $0.id == defaultOutputID })?.id ?? outputDevices.first?.id
            }

            if tracks.isEmpty {
                addTrack(layout: .mono)
            }

            sanitizeTracks()
            sanitizeLatencyBufferSettings()
            wavesTuneState.normalize()
            updateSessionWarnings()
            try refreshManagedSessions()
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

    func handleDeviceSelectionChange() {
        sanitizeTracks()
        updateSessionWarnings()
    }

    func createNewSession() {
        guard !isRunning else { return }
        isApplyingSessionState = true
        selectedInputDeviceID = inputDevices.first?.id
        selectedOutputDeviceID = outputDevices.first?.id
        selectedBufferSize = DefaultBufferSizes.preferredHardwareBufferSize(from: availableBufferSizes) ?? DefaultBufferSizes.hardwareFrames
        customBufferSizeText = String(selectedBufferSize)
        latencyBufferSettings = MultiTrackLatencyBufferSettings(hardwareBufferSize: selectedBufferSize)
        bufferedInternalBufferText = String(latencyBufferSettings.bufferedFrames)
        broadcastInternalBufferText = String(latencyBufferSettings.broadcastFrames)
        tracks = []
        addTrack(layout: .mono)
        wavesTuneState = MultiTrackWavesTuneState()
        currentSessionURL = nil
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
        sanitizedSessionFilename(from: currentSessionName)
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
        currentSessionName = sessionDisplayName(for: url)
        hasUnsavedChanges = false
        try refreshManagedSessions()
        statusMessage = "Saved \(currentSessionName)."
    }

    func rememberExportedSessionURL(_ url: URL) {
        currentSessionURL = url
        currentSessionName = sessionDisplayName(for: url)
        statusMessage = "Saved \(currentSessionName)."
    }

    func loadSession(from url: URL) throws {
        let data = try Data(contentsOf: url)
        let session: MultiTrackSessionFile
        do {
            session = try JSONDecoder().decode(MultiTrackSessionFile.self, from: data)
        } catch {
            throw AudioHostError("Failed to read the multi-track session file.")
        }
        applySession(session, sourceURL: url)
        try refreshManagedSessions()
    }

    func refreshManagedSessions() throws {
        managedSessions = try SAHManagedSessionStore.managedSessions()
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
            throw AudioHostError("Failed to read the chain preset file.")
        }

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
            throw AudioHostError("Failed to read the parameter preset file.")
        }

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
        guard let selectedInputDevice else { return [] }
        let maxStart = max(1, selectedInputDevice.inputChannelCount - track.channelCount + 1)
        return Array(1...maxStart)
    }

    func availableOutputStartChannels(for track: MultiTrackTrackConfiguration) -> [Int] {
        guard let selectedOutputDevice else { return [] }
        let maxStart = max(1, selectedOutputDevice.outputChannelCount - track.channelCount + 1)
        return Array(1...maxStart).filter { candidate in
            outputChannelsAreAvailable(
                for: sanitizedTrack(track),
                proposedStartChannel: candidate
            )
        }
    }

    func internalBufferDescription(for track: MultiTrackTrackConfiguration) -> String {
        let internalFrames = latencyBufferSettings.internalFrames(
            for: track.latencyClass,
            hardwareBufferSize: selectedBufferSize
        )
        return "\(track.latencyClass.title): \(internalFrames) internal frames"
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

    func toggleStartStop() {
        if isRunning {
            clearEmbeddedPluginEditor()
            audioDropoutMonitorTask?.cancel()
            audioDropoutMonitorTask = nil
            refreshPublishedTelemetry()
            captureLivePluginStates()
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
                _ = try self.controller.setWavesTuneRealtimeBypassed(!self.wavesTuneState.isEnabled)
                _ = try self.controller.applyWavesTuneRealtimeKeySelection(self.wavesTuneState.appliedKey.normalized)
                self.isRunning = true
                self.refreshPublishedTelemetry()
                self.startAudioDropoutMonitoring()
                self.statusMessage = "Running."
            } catch {
                self.audioDropoutMonitorTask?.cancel()
                self.audioDropoutMonitorTask = nil
                self.refreshPublishedTelemetry()
                self.clearEmbeddedPluginEditor()
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

    private func applySession(_ session: MultiTrackSessionFile, sourceURL: URL?) {
        isApplyingSessionState = true
        selectedInputDeviceID = session.inputDeviceID
        selectedOutputDeviceID = session.outputDeviceID
        selectedBufferSize = session.bufferSize
        customBufferSizeText = String(session.bufferSize)
        latencyBufferSettings = session.latencyBufferSettings
        bufferedInternalBufferText = String(session.latencyBufferSettings.bufferedFrames)
        broadcastInternalBufferText = String(session.latencyBufferSettings.broadcastFrames)
        tracks = session.tracks.isEmpty
            ? [MultiTrackTrackConfiguration(name: "Track 1", layout: .mono)]
            : session.tracks

        currentSessionURL = sourceURL
        currentSessionName = sourceURL.map(sessionDisplayName(for:)) ?? session.name
        wavesTuneState = session.wavesTuneState ?? MultiTrackWavesTuneState()
        wavesTuneState.normalize()

        sanitizeTracks()
        sanitizeLatencyBufferSettings()
        updateSessionWarnings()

        isApplyingSessionState = false
        hasUnsavedChanges = false
        statusMessage = "Loaded \(currentSessionName)."
    }

    private func sanitizeTracks() {
        for index in tracks.indices {
            tracks[index] = sanitizedTrack(tracks[index])
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

    private func sanitizeLatencyBufferSettings() {
        latencyBufferSettings.bufferedFrames = normalizedInternalBufferSize(latencyBufferSettings.bufferedFrames)
        latencyBufferSettings.broadcastFrames = normalizedInternalBufferSize(latencyBufferSettings.broadcastFrames)
        bufferedInternalBufferText = String(latencyBufferSettings.bufferedFrames)
        broadcastInternalBufferText = String(latencyBufferSettings.broadcastFrames)
    }

    private func updateSessionWarnings() {
        var warnings: [String] = []

        if let selectedInputDeviceID, !inputDevices.contains(where: { $0.id == selectedInputDeviceID }) {
            warnings.append("Saved input device is not currently available. Reconnect it or choose another input before starting.")
        }

        if let selectedOutputDeviceID, !outputDevices.contains(where: { $0.id == selectedOutputDeviceID }) {
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
            inputDeviceID: selectedInputDeviceID,
            outputDeviceID: selectedOutputDeviceID,
            bufferSize: selectedBufferSize,
            latencyBufferSettings: latencyBufferSettings,
            tracks: tracks.map(sanitizedTrack),
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
        applyTelemetrySnapshot(
            dropoutCount: controller.audioDropoutCount(),
            droppedFrameCount: controller.droppedFrameCount(),
            telemetry: controller.telemetrySnapshot()
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
}
