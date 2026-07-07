import Foundation

extension MultiTrackViewModel {
    var configuredTuneInsertCount: Int {
        tracks
            .filter(\.isEnabled)
            .reduce(into: 0) { count, track in
                for insert in track.plugins {
                    guard let pluginID = insert.pluginID,
                          let plugin = plugins.first(where: { $0.id == pluginID }),
                          isTunerPlugin(plugin) else {
                        continue
                    }
                    count += 1
                }
            }
    }

    var performTracks: [MultiTrackTrackConfiguration] {
        tracks.filter(trackHasConfiguredTuneInsert)
    }

    var stagedTuneKeyTitle: String {
        tuneState.stagedKey.title
    }

    var appliedTuneKeyTitle: String {
        tuneState.appliedKey.title
    }

    var canApplyStagedTuneKey: Bool {
        tuneState.stagedKey.normalized != tuneState.appliedKey.normalized
    }

    var tuneSongs: [TuneSongEntry] {
        tuneState.songs
    }

    var selectedTuneSong: TuneSongEntry? {
        guard let selectedSongID = tuneState.selectedSongID else { return nil }
        return tuneState.songs.first { $0.id == selectedSongID }
    }

    var selectedTuneSongIndex: Int? {
        guard let selectedSongID = tuneState.selectedSongID else { return nil }
        return tuneState.songs.firstIndex { $0.id == selectedSongID }
    }

    var selectedTuneSongTitle: String {
        guard let selectedTuneSongIndex else { return "No Song Selected" }
        return tuneSongDisplayTitle(for: tuneState.songs[selectedTuneSongIndex], index: selectedTuneSongIndex)
    }

    var selectedTuneSongKeyTitle: String {
        selectedTuneSong?.key.title ?? "Select a song to apply its key."
    }

    var previousTuneSongIndex: Int? {
        guard !tuneState.songs.isEmpty else { return nil }
        guard let selectedTuneSongIndex else { return tuneState.songs.count - 1 }
        let previousIndex = selectedTuneSongIndex - 1
        return tuneState.songs.indices.contains(previousIndex) ? previousIndex : nil
    }

    var nextTuneSongIndex: Int? {
        guard !tuneState.songs.isEmpty else { return nil }
        guard let selectedTuneSongIndex else { return 0 }
        let nextIndex = selectedTuneSongIndex + 1
        return tuneState.songs.indices.contains(nextIndex) ? nextIndex : nil
    }

    var canSelectPreviousTuneSong: Bool {
        guard let selectedTuneSongIndex else { return false }
        return selectedTuneSongIndex > 0
    }

    var canSelectNextTuneSong: Bool {
        guard !tuneState.songs.isEmpty else { return false }
        guard let selectedTuneSongIndex else { return true }
        return selectedTuneSongIndex < tuneState.songs.count - 1
    }

    var canSaveStagedKeyToSelectedTuneSong: Bool {
        selectedTuneSongIndex != nil
    }

    func tuneStrengthParameterSummary(for track: MultiTrackTrackConfiguration) -> String {
        guard let profile = tuneStrengthParameterProfile(for: track),
              let summary = track.tuneStrength.parameterSummary(for: profile) else {
            return "Uses current plugin values"
        }
        return summary
    }

    func setTuneEnabled(_ isEnabled: Bool) {
        tuneState.isEnabled = isEnabled

        guard isRunning else {
            statusMessage = configuredTuneInsertCount > 0
                ? "Tuner inserts will start \(isEnabled ? "enabled" : "bypassed")."
                : "No tuner inserts are configured."
            return
        }

        do {
            let affectedInstances = try controller.setTuneBypassed(!isEnabled)
            statusMessage = affectedInstances > 0
                ? "Set tuner \(isEnabled ? "active" : "bypassed") on \(affectedInstances) instance(s)."
                : "No running tuner instances were found."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func setTuneStrength(_ strength: TuneStrengthPreset, for trackID: UUID) {
        guard let trackIndex = tracks.firstIndex(where: { $0.id == trackID }) else { return }
        let track = tracks[trackIndex]
        guard track.tuneStrength != strength else { return }

        tracks[trackIndex].tuneStrength = strength

        guard strength != .custom else {
            statusMessage = isRunning
                ? "Left \(tracks[trackIndex].name) on its current tune settings."
                : "\(tracks[trackIndex].name) will keep its current tune settings."
            return
        }

        guard isRunning else {
            statusMessage = trackHasConfiguredTuneInsert(tracks[trackIndex])
                ? "\(tracks[trackIndex].name) tune strength saved as \(strength.title)."
                : "\(tracks[trackIndex].name) does not have a tuner loaded."
            return
        }

        guard tracks[trackIndex].isEnabled else {
            statusMessage = "\(tracks[trackIndex].name) is disabled. \(strength.title) will apply when the track is enabled and started."
            return
        }

        do {
            let affectedInstances = try controller.applyTuneStrength(strength, to: trackID)
            refreshTuneStrengthSelectionFromRunningEngine(for: trackID)
            statusMessage = affectedInstances > 0
                ? "Set \(tracks[trackIndex].name) to \(tracks[trackIndex].tuneStrength.title) tune strength."
                : "No running tuner instances were found on \(tracks[trackIndex].name)."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func setTuneScaleMode(_ scaleMode: TuneScaleMode) {
        tuneState.stagedKey.scaleMode = scaleMode
    }

    func setTuneNoteLetter(_ noteLetter: TuneNoteLetter) {
        tuneState.stagedKey.noteLetter = noteLetter
        tuneState.stagedKey.normalize()
    }

    func setTuneAccidental(_ accidental: TuneAccidental) {
        guard TuneKeySelection.supports(accidental: accidental, for: tuneState.stagedKey.noteLetter) else {
            return
        }
        tuneState.stagedKey.accidental = accidental
    }

    func addTuneSong(title: String, key: TuneKeySelection) {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            statusMessage = "Enter a song name."
            return
        }

        let song = TuneSongEntry(
            title: trimmedTitle,
            key: key.normalized
        )
        tuneState.songs.append(song)
        activateTuneSong(at: tuneState.songs.count - 1, action: "Added")
    }

    func removeTuneSong(_ id: UUID) {
        guard let index = tuneState.songs.firstIndex(where: { $0.id == id }) else { return }
        let removedTitle = tuneSongDisplayTitle(for: tuneState.songs[index], index: index)
        let removedWasSelected = tuneState.selectedSongID == id
        tuneState.songs.remove(at: index)

        guard removedWasSelected else {
            statusMessage = "Removed \(removedTitle)."
            return
        }

        guard !tuneState.songs.isEmpty else {
            tuneState.selectedSongID = nil
            statusMessage = "Removed \(removedTitle)."
            return
        }

        activateTuneSong(at: min(index, tuneState.songs.count - 1), action: "Selected")
    }

    func updateTuneSongTitle(_ id: UUID, title: String) {
        guard let index = tuneState.songs.firstIndex(where: { $0.id == id }) else { return }
        tuneState.songs[index].title = title
    }

    func updateTuneSongNotes(_ id: UUID, notes: String) {
        guard let index = tuneState.songs.firstIndex(where: { $0.id == id }) else { return }
        tuneState.songs[index].notes = notes
    }

    func moveTuneSong(_ id: UUID, direction: Int) {
        guard direction != 0 else { return }
        guard let index = tuneState.songs.firstIndex(where: { $0.id == id }) else { return }
        let targetIndex = index + direction
        guard tuneState.songs.indices.contains(targetIndex) else { return }
        let song = tuneState.songs.remove(at: index)
        tuneState.songs.insert(song, at: targetIndex)
        tuneState.selectedSongID = song.id
        statusMessage = "Moved \(tuneSongDisplayTitle(for: song, index: targetIndex))."
    }

    func duplicateTuneSong(_ id: UUID) {
        guard let index = tuneState.songs.firstIndex(where: { $0.id == id }) else { return }
        let source = tuneState.songs[index]
        let duplicate = TuneSongEntry(
            title: "\(source.title) Copy",
            key: source.key.normalized,
            notes: source.notes
        )
        let targetIndex = index + 1
        tuneState.songs.insert(duplicate, at: targetIndex)
        activateTuneSong(at: targetIndex, action: "Duplicated")
    }

    func selectTuneSong(_ id: UUID) {
        guard let index = tuneState.songs.firstIndex(where: { $0.id == id }) else { return }
        activateTuneSong(at: index, action: "Selected")
    }

    func stepTuneSong(direction: Int) {
        guard direction != 0, !tuneState.songs.isEmpty else { return }

        let targetIndex: Int
        if let selectedTuneSongIndex {
            let nextIndex = selectedTuneSongIndex + direction
            guard tuneState.songs.indices.contains(nextIndex) else { return }
            targetIndex = nextIndex
        } else if direction > 0 {
            targetIndex = 0
        } else {
            targetIndex = tuneState.songs.count - 1
        }

        activateTuneSong(at: targetIndex, action: "Selected")
    }

    func triggerTuneKeyPanic() {
        var chromaticSelection = tuneState.appliedKey.normalized
        chromaticSelection.scaleMode = .chromatic
        setActiveTuneKey(
            chromaticSelection,
            offlineMessage: "Key Panic armed. Start the engine to apply Chromatic.",
            onlineMessage: { affectedInstances in
                "Key Panic applied Chromatic to \(affectedInstances) instance(s)."
            }
        )
    }

    func saveStagedKeyToSelectedTuneSong() {
        guard let selectedTuneSongIndex else {
            statusMessage = "Select a song first."
            return
        }

        let normalizedKey = tuneState.stagedKey.normalized
        tuneState.songs[selectedTuneSongIndex].key = normalizedKey
        activateTuneSong(at: selectedTuneSongIndex, action: "Saved")
    }

    func applyStagedTuneKey() {
        let normalizedKey = tuneState.stagedKey.normalized
        setActiveTuneKey(
            normalizedKey,
            offlineMessage: "Saved tune key \(normalizedKey.title). Start the engine to apply it.",
            onlineMessage: { affectedInstances in
                "Applied tune key \(normalizedKey.title) to \(affectedInstances) instance(s)."
            }
        )
    }

    private func activateTuneSong(at index: Int, action: String) {
        guard tuneState.songs.indices.contains(index) else { return }

        tuneState.songs[index].key = tuneState.songs[index].key.normalized
        tuneState.selectedSongID = tuneState.songs[index].id

        let song = tuneState.songs[index]
        let songTitle = tuneSongDisplayTitle(for: song, index: index)
        setActiveTuneKey(
            song.key,
            offlineMessage: "\(action) \(songTitle). Start the engine to apply \(song.key.title).",
            onlineMessage: { affectedInstances in
                "\(action) \(songTitle). Applied \(song.key.title) to \(affectedInstances) instance(s)."
            }
        )
    }

    private func setActiveTuneKey(
        _ selection: TuneKeySelection,
        offlineMessage: String,
        onlineMessage: (Int) -> String
    ) {
        let normalizedSelection = selection.normalized
        tuneState.stagedKey = normalizedSelection
        tuneState.appliedKey = normalizedSelection

        guard isRunning else {
            statusMessage = configuredTuneInsertCount > 0
                ? offlineMessage
                : "\(offlineMessage) No tuner inserts are configured."
            return
        }

        do {
            let affectedInstances = try controller.applyTuneKeySelection(normalizedSelection)
            statusMessage = affectedInstances > 0
                ? onlineMessage(affectedInstances)
                : "No running tuner instances were found."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func tuneSongDisplayTitle(for song: TuneSongEntry, index: Int) -> String {
        let trimmedTitle = song.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedTitle.isEmpty ? "Song \(index + 1)" : trimmedTitle
    }

    private func isTunerPlugin(_ plugin: AudioUnitPluginInfo) -> Bool {
        WavesTuneRealtimeParameterMap.matches(plugin)
            || SimpleLiveTuneParameterMap.matches(plugin)
    }

    private func tuneStrengthParameterProfile(
        for track: MultiTrackTrackConfiguration
    ) -> TuneStrengthParameterProfile? {
        var hasWavesTuneRealtime = false
        var hasSimpleLiveTune = false

        for insert in track.plugins {
            guard let pluginID = insert.pluginID,
                  let plugin = plugins.first(where: { $0.id == pluginID }) else {
                continue
            }

            if WavesTuneRealtimeParameterMap.matches(plugin) {
                hasWavesTuneRealtime = true
            }

            if SimpleLiveTuneParameterMap.matches(plugin) {
                hasSimpleLiveTune = true
            }
        }

        switch (hasWavesTuneRealtime, hasSimpleLiveTune) {
        case (true, true):
            return .mixed
        case (true, false):
            return .wavesTuneRealtime
        case (false, true):
            return .simpleLiveTune
        case (false, false):
            return nil
        }
    }

    private func trackHasConfiguredTuneInsert(_ track: MultiTrackTrackConfiguration) -> Bool {
        track.plugins.contains { insert in
            guard let pluginID = insert.pluginID,
                  let plugin = plugins.first(where: { $0.id == pluginID }) else {
                return false
            }
            return isTunerPlugin(plugin)
        }
    }

    func syncTuneStrengthSelectionsFromRunningEngine() {
        let existingHasUnsavedChanges = hasUnsavedChanges
        isApplyingSessionState = true
        defer {
            isApplyingSessionState = false
            hasUnsavedChanges = existingHasUnsavedChanges
        }

        for track in tracks where track.isEnabled && trackHasConfiguredTuneInsert(track) {
            refreshTuneStrengthSelectionFromRunningEngine(for: track.id)
        }
    }

    private func refreshTuneStrengthSelectionFromRunningEngine(for trackID: UUID) {
        guard let trackIndex = tracks.firstIndex(where: { $0.id == trackID }) else { return }

        do {
            guard let preset = try controller.currentTuneStrengthPreset(for: trackID) else { return }
            tracks[trackIndex].tuneStrength = preset
        } catch {
            statusMessage = error.localizedDescription
        }
    }
}
