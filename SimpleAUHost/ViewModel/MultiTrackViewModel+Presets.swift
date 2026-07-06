import Foundation

struct CopiedTrackProcessing {
    let sourceTrackName: String
    let inserts: [MultiTrackTrackConfiguration.PluginInsert]
}

extension MultiTrackViewModel {
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

    func saveChainPreset(for trackID: UUID, to url: URL) async throws {
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

        let resolvedURL = normalizedURL(url, pathExtension: "sahchain")
        try await Task.detached(priority: .userInitiated) {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(preset)
            try data.write(to: resolvedURL, options: .atomic)
        }.value
        statusMessage = "Saved chain preset \(resolvedURL.deletingPathExtension().lastPathComponent)."
    }

    func loadChainPreset(for trackID: UUID, from url: URL) async throws {
        let preset: MultiTrackChainPresetFile = try await Task.detached(priority: .userInitiated) {
            let data = try Data(contentsOf: url)
            do {
                let decoded = try JSONDecoder().decode(MultiTrackChainPresetFile.self, from: data)
                try decoded.validateFormatVersion()
                return decoded
            } catch {
                throw AudioHostError("Failed to read the chain preset file: \(error.localizedDescription)")
            }
        }.value

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

    func saveParameterPreset(for trackID: UUID, to url: URL) async throws {
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

        let resolvedURL = normalizedURL(url, pathExtension: "sahparams")
        try await Task.detached(priority: .userInitiated) {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(preset)
            try data.write(to: resolvedURL, options: .atomic)
        }.value
        statusMessage = "Saved parameter preset \(resolvedURL.deletingPathExtension().lastPathComponent)."
    }

    func loadParameterPreset(for trackID: UUID, from url: URL) async throws {
        let preset: MultiTrackParameterPresetFile = try await Task.detached(priority: .userInitiated) {
            let data = try Data(contentsOf: url)
            do {
                let decoded = try JSONDecoder().decode(MultiTrackParameterPresetFile.self, from: data)
                try decoded.validateFormatVersion()
                return decoded
            } catch {
                throw AudioHostError("Failed to read the parameter preset file: \(error.localizedDescription)")
            }
        }.value

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
}
