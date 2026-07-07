import Foundation

enum WavesTuneScaleMode: String, CaseIterable, Codable, Identifiable {
    case chromatic
    case major
    case minor

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chromatic: "Chromatic"
        case .major: "Major"
        case .minor: "Minor"
        }
    }

    var pluginValue: Int {
        switch self {
        case .chromatic: 1
        case .major: 2
        case .minor: 3
        }
    }

    var simpleLiveTunePluginValue: Int {
        switch self {
        case .chromatic: 0
        case .major: 1
        case .minor: 2
        }
    }
}

enum WavesTuneNoteLetter: String, CaseIterable, Codable, Identifiable {
    case c
    case d
    case e
    case f
    case g
    case a
    case b

    var id: String { rawValue }

    var title: String { rawValue.uppercased() }
}

enum WavesTuneAccidental: String, CaseIterable, Codable, Identifiable {
    case flat
    case natural
    case sharp

    var id: String { rawValue }

    var title: String {
        switch self {
        case .flat: "♭"
        case .natural: "♮"
        case .sharp: "♯"
        }
    }

    var symbol: String {
        switch self {
        case .flat: "b"
        case .natural: ""
        case .sharp: "#"
        }
    }
}

struct WavesTuneKeySelection: Codable, Hashable {
    var scaleMode: WavesTuneScaleMode = .chromatic
    var noteLetter: WavesTuneNoteLetter = .c
    var accidental: WavesTuneAccidental = .natural

    var title: String {
        if scaleMode == .chromatic {
            return scaleMode.title
        }
        return "\(rootTitle) \(scaleMode.title)"
    }

    var rootTitle: String {
        noteLetter.title + accidental.symbol
    }

    var pluginScaleTypeValue: Int {
        scaleMode.pluginValue
    }

    var pluginScaleRootValue: Int {
        return switch (noteLetter, accidental) {
        case (.c, .natural): 0
        case (.c, .sharp): 1
        case (.d, .flat): 2
        case (.d, .natural): 3
        case (.d, .sharp): 4
        case (.e, .flat): 5
        case (.e, .natural): 6
        case (.f, .natural): 7
        case (.f, .sharp): 8
        case (.g, .flat): 9
        case (.g, .natural): 10
        case (.g, .sharp): 11
        case (.a, .flat): 12
        case (.a, .natural): 13
        case (.a, .sharp): 14
        case (.b, .flat): 15
        case (.b, .natural): 16
        case (.c, .flat), (.e, .sharp), (.f, .flat), (.b, .sharp):
            normalized.pluginScaleRootValue
        }
    }

    var simpleLiveTuneKeyValue: Int {
        let letterSemitone = switch noteLetter {
        case .c: 0
        case .d: 2
        case .e: 4
        case .f: 5
        case .g: 7
        case .a: 9
        case .b: 11
        }
        let accidentalOffset = switch accidental {
        case .flat: -1
        case .natural: 0
        case .sharp: 1
        }
        return (letterSemitone + accidentalOffset + 12) % 12
    }

    var normalized: WavesTuneKeySelection {
        var selection = self
        selection.normalize()
        return selection
    }

    mutating func normalize() {
        if !Self.supports(accidental: accidental, for: noteLetter) {
            accidental = .natural
        }
    }

    static func supports(
        accidental: WavesTuneAccidental,
        for noteLetter: WavesTuneNoteLetter
    ) -> Bool {
        switch (noteLetter, accidental) {
        case (_, .natural):
            true
        case (.c, .sharp), (.d, .sharp), (.f, .sharp), (.g, .sharp), (.a, .sharp):
            true
        case (.d, .flat), (.e, .flat), (.g, .flat), (.a, .flat), (.b, .flat):
            true
        default:
            false
        }
    }
}

struct WavesTuneSongEntry: Identifiable, Codable, Hashable {
    let id: UUID
    var title: String
    var key: WavesTuneKeySelection
    var notes: String

    init(
        id: UUID = UUID(),
        title: String,
        key: WavesTuneKeySelection = WavesTuneKeySelection(),
        notes: String = ""
    ) {
        self.id = id
        self.title = title
        self.key = key
        self.notes = notes
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case key
        case notes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        key = try container.decode(WavesTuneKeySelection.self, forKey: .key)
        notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
    }

    var normalized: WavesTuneSongEntry {
        var song = self
        song.key = key.normalized
        return song
    }
}

struct MultiTrackWavesTuneState: Codable, Hashable {
    var isEnabled = true
    var stagedKey = WavesTuneKeySelection()
    var appliedKey = WavesTuneKeySelection()
    var songs: [WavesTuneSongEntry] = []
    var selectedSongID: UUID?

    var normalized: MultiTrackWavesTuneState {
        var state = self
        state.normalize()
        return state
    }

    mutating func normalize() {
        stagedKey = stagedKey.normalized
        appliedKey = appliedKey.normalized
        songs = songs.map(\.normalized)
        if let selectedSongID, !songs.contains(where: { $0.id == selectedSongID }) {
            self.selectedSongID = nil
        }
    }
}

enum WavesTuneStrengthPreset: String, CaseIterable, Codable, Identifiable {
    case fast
    case standard
    case slow
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fast:
            "Fast"
        case .standard:
            "Standard"
        case .slow:
            "Slow"
        case .custom:
            "Custom"
        }
    }

    var speed: Float? {
        switch self {
        case .fast:
            15
        case .standard:
            20
        case .slow:
            30
        case .custom:
            nil
        }
    }

    var noteTransition: Float? {
        switch self {
        case .fast:
            60
        case .standard:
            90
        case .slow:
            120
        case .custom:
            nil
        }
    }

    var pluginSpeedValue: Float? {
        speed.map { $0 * 10 }
    }

    var pluginNoteTransitionValue: Float? {
        noteTransition.map { $0 * 10 }
    }

    var simpleLiveTuneRetuneSpeed: Float? {
        switch self {
        case .fast:
            15
        case .standard:
            20
        case .slow:
            40
        case .custom:
            nil
        }
    }

    var simpleLiveTuneNoteTransition: Float? {
        switch self {
        case .fast:
            50
        case .standard:
            60
        case .slow:
            90
        case .custom:
            nil
        }
    }

    static func matchingDisplayValues(
        speed: Float,
        noteTransition: Float
    ) -> WavesTuneStrengthPreset {
        for preset in [WavesTuneStrengthPreset.fast, .standard, .slow] {
            guard let presetSpeed = preset.speed,
                  let presetTransition = preset.noteTransition else {
                continue
            }

            if abs(speed - presetSpeed) < 0.25, abs(noteTransition - presetTransition) < 0.25 {
                return preset
            }
        }

        return .custom
    }

    static func matchingSimpleLiveTuneValues(
        retuneSpeed: Float,
        noteTransition: Float
    ) -> WavesTuneStrengthPreset {
        for preset in [WavesTuneStrengthPreset.fast, .standard, .slow] {
            guard let presetRetuneSpeed = preset.simpleLiveTuneRetuneSpeed,
                  let presetNoteTransition = preset.simpleLiveTuneNoteTransition else {
                continue
            }

            if abs(retuneSpeed - presetRetuneSpeed) <= 0.25,
               abs(noteTransition - presetNoteTransition) <= 0.25 {
                return preset
            }
        }
        return .custom
    }
}
