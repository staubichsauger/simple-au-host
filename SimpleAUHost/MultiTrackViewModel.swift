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

    private let catalog = AudioHostController()
    private let controller = MultiTrackAudioHostController()
    private var latencyBufferSettings = MultiTrackLatencyBufferSettings(hardwareBufferSize: 128)
    private var audioDropoutMonitorTask: Task<Void, Never>?
    private var currentSessionURL: URL?

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
        do {
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
            updateSessionWarnings()
            updateSessionNameIfNeeded()
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
        updateSessionWarnings()
    }

    func createNewSession() {
        guard !isRunning else { return }
        selectedInputDeviceID = inputDevices.first?.id
        selectedOutputDeviceID = outputDevices.first?.id
        selectedBufferSize = availableBufferSizes.first ?? 128
        customBufferSizeText = String(selectedBufferSize)
        latencyBufferSettings = MultiTrackLatencyBufferSettings(hardwareBufferSize: selectedBufferSize)
        bufferedInternalBufferText = String(latencyBufferSettings.bufferedFrames)
        broadcastInternalBufferText = String(latencyBufferSettings.broadcastFrames)
        tracks = []
        addTrack(layout: .mono)
        currentSessionURL = nil
        currentSessionName = "Untitled Session"
        sessionWarnings = []
        statusMessage = "Ready."
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
        captureLivePluginStates()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(makeSessionFile())
        try data.write(to: currentSessionURL, options: .atomic)
        currentSessionName = sessionDisplayName(for: currentSessionURL)
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
            audioDropoutCount = controller.audioDropoutCount()
            droppedFrameCount = controller.droppedFrameCount()
            updateTelemetry()
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
                self.updateTelemetry()
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

        sanitizeTracks()
        sanitizeLatencyBufferSettings()
        updateSessionWarnings()

        statusMessage = "Loaded \(currentSessionName)."
    }

    private func sanitizeTracks() {
        for index in tracks.indices {
            tracks[index] = sanitizedTrack(tracks[index])
        }
        if tracks.isEmpty {
            tracks = [MultiTrackTrackConfiguration(name: "Track 1", layout: .mono)]
        }
        if let firstBuffer = availableBufferSizes.first, !isSelectedBufferSizeValid {
            selectedBufferSize = firstBuffer
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
            tracks: tracks.map(sanitizedTrack)
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
        audioDropoutCount = controller.audioDropoutCount()
        droppedFrameCount = controller.droppedFrameCount()
        updateTelemetry()
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

    private func sessionDisplayName(for url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }

    private func sanitizedSessionFilename(from name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseName = trimmed.isEmpty ? "MultiTrack Session" : trimmed
        let invalidCharacters = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let cleaned = String(baseName.unicodeScalars.map { invalidCharacters.contains($0) ? "-" : Character($0) })
        return cleaned.hasSuffix(".sahsession") ? cleaned : "\(cleaned).sahsession"
    }
}
