import Foundation

extension MultiTrackViewModel {
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

    func retrySessionDeviceResolution() {
        guard let retryContext = sessionReloadRetryContext else { return }

        sessionDeviceResolutionAlert = nil
        Task { [weak self] in
            guard let self else { return }
            // Rescan devices first so the session's saved device UID can resolve.
            await self.loadAsync()
            do {
                try await self.loadSessionAsync(from: retryContext.sessionURL)
                if retryContext.reopensAsTemplate {
                    self.openCurrentSessionAsTemplate()
                }
                self.startEngine()
            } catch {
                self.statusMessage = "Failed to reload \(self.sessionDisplayName(for: retryContext.sessionURL)): \(error.localizedDescription)"
            }
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
        tuneState = MultiTrackTuneState()
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

    /// Synchronous save, kept deliberately: the window/app close flow
    /// (`AppCloseCoordinator`) must know whether the save succeeded before the
    /// close proceeds. All other save paths should use `saveSessionAsync`.
    func saveSession() throws {
        guard let currentSessionURL else {
            throw AudioHostError("Choose Save As to create a session file first.")
        }
        try saveSession(to: currentSessionURL)
    }

    /// Synchronous save for the close flow and Save As panel; see `saveSession()`.
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

    func applySession(_ session: MultiTrackSessionFile, sourceURL: URL?) {
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
        tuneState = session.tuneState ?? MultiTrackTuneState()
        tuneState.normalize()

        sanitizeTracks(clampTrackRouting: false)
        updateSessionWarnings()

        isApplyingSessionState = false
        hasUnsavedChanges = false
        statusMessage = "Loaded \(currentSessionName)."
    }

    func sanitizeTracks(clampTrackRouting: Bool = true) {
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

    func resolvedSessionDeviceID(
        preferredUID: String?,
        availableDevices: [AudioDeviceInfo]
    ) -> AudioDeviceID? {
        if let preferredUID,
           let matchedDeviceID = availableDevices.first(where: { $0.uid == preferredUID })?.id {
            return matchedDeviceID
        }

        return nil
    }

    func sanitizeLatencyBufferSettings() {
        latencyBufferSettings.bufferedFrames = normalizedInternalBufferSize(latencyBufferSettings.bufferedFrames)
        latencyBufferSettings.broadcastFrames = normalizedInternalBufferSize(latencyBufferSettings.broadcastFrames)
        latencyBufferSettings.broadcastPrerollMultiplier = normalizedBroadcastPrerollMultiplier(
            latencyBufferSettings.broadcastPrerollMultiplier
        )
        bufferedInternalBufferText = String(latencyBufferSettings.bufferedFrames)
        broadcastInternalBufferText = String(latencyBufferSettings.broadcastFrames)
        broadcastPrerollMultiplier = latencyBufferSettings.broadcastPrerollMultiplier
    }

    func makeSessionFile() -> MultiTrackSessionFile {
        captureLivePluginStates()
        return MultiTrackSessionFile(
            name: currentSessionURL.map(sessionDisplayName(for:)) ?? currentSessionName,
            inputDeviceUID: selectedInputDevice?.uid,
            outputDeviceUID: selectedOutputDevice?.uid,
            bufferSize: selectedBufferSize,
            latencyBufferSettings: latencyBufferSettings,
            tracks: tracks,
            tuneState: tuneState.normalized
        )
    }

    func captureLivePluginStates() {
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

    func updateSessionNameIfNeeded() {
        if let currentSessionURL {
            currentSessionName = sessionDisplayName(for: currentSessionURL)
        }
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

    func presentSessionDeviceResolutionAlertIfNeeded() -> Bool {
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

    func sessionDisplayName(for url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }

    private func sanitizedSessionFilename(from name: String) -> String {
        sanitizedFilename(from: name, pathExtension: "sahsession")
    }

    func sanitizedFilename(from name: String, pathExtension: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseName = trimmed.isEmpty ? "MultiTrack Session" : trimmed
        let invalidCharacters = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let cleaned = String(baseName.unicodeScalars.map { invalidCharacters.contains($0) ? "-" : Character($0) })
        let dottedExtension = ".\(pathExtension)"
        return cleaned.hasSuffix(dottedExtension) ? cleaned : "\(cleaned)\(dottedExtension)"
    }

    func normalizedURL(_ url: URL, pathExtension: String) -> URL {
        if url.pathExtension.caseInsensitiveCompare(pathExtension) == .orderedSame {
            return url
        }
        return url.appendingPathExtension(pathExtension)
    }

    func loadPersistedStartupPreferences() {
        let preferences = startupPreferencesStore.load()
        launchesIntoPerformViewOnStartup = preferences.launchesIntoPerformViewOnStartup
        loadsSavedSessionOnStartup = preferences.loadsSavedSessionOnStartup
        startsEngineOnLaunch = preferences.startsEngineOnLaunch
        startupSavedSessionSelection = preferences.savedSessionSelection
        startupSpecificSessionURL = preferences.specificSessionURL
        opensStartupSpecificSessionAsTemplate = preferences.opensSpecificSessionAsTemplate
        lastSavedSessionURL = preferences.lastSavedSessionURL
    }

    func persistStartupPreferences() {
        startupPreferencesStore.persist(
            StartupPreferences(
                launchesIntoPerformViewOnStartup: launchesIntoPerformViewOnStartup,
                loadsSavedSessionOnStartup: loadsSavedSessionOnStartup,
                startsEngineOnLaunch: startsEngineOnLaunch,
                savedSessionSelection: startupSavedSessionSelection,
                specificSessionURL: startupSpecificSessionURL,
                opensSpecificSessionAsTemplate: opensStartupSpecificSessionAsTemplate,
                lastSavedSessionURL: lastSavedSessionURL
            )
        )
    }

    func recordLastSavedSessionURL(_ url: URL) {
        lastSavedSessionURL = url
        startupPreferencesStore.recordLastSavedSessionURL(url)
    }
}
