import Foundation

extension MultiTrackViewModel {
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
        WavesTuneRealtimeParameterMap.matches(plugin)
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

    func syncWavesTuneStrengthSelectionsFromRunningEngine() {
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
}
