import Foundation

@MainActor
private enum CompanionControlTimestampFormatter {
    static let iso8601Formatter = ISO8601DateFormatter()
}

extension MultiTrackViewModel {
    func companionControlStateSnapshot() -> CompanionControlStateSnapshot {
        CompanionControlStateSnapshot(
            apiVersion: 1,
            appMode: "multiTrack",
            timestamp: CompanionControlTimestampFormatter.iso8601Formatter.string(from: Date()),
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

    func startCompanionControlServer() {
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
}

enum CompanionControlRootChoice: String {
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
