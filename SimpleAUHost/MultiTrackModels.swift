import Foundation
import SwiftUI
import UniformTypeIdentifiers

enum DefaultBufferSizes {
    static let hardwareFrames = 32
    static let bufferedFrames = 128
    static let broadcastFrames = 512
    static let broadcastPrerollMultiplier = 1

    static func preferredHardwareBufferSize(from candidates: [Int]) -> Int? {
        let sortedCandidates = candidates.sorted()
        if sortedCandidates.contains(hardwareFrames) {
            return hardwareFrames
        }
        if let nextHigherCandidate = sortedCandidates.first(where: { $0 > hardwareFrames }) {
            return nextHigherCandidate
        }
        return sortedCandidates.last
    }

    static func preferredInternalBufferSize(defaultFrames: Int, hardwareBufferSize: Int) -> Int {
        let normalizedHardwareBufferSize = max(1, hardwareBufferSize)
        let minimumFrames = max(defaultFrames, normalizedHardwareBufferSize)
        let remainder = minimumFrames % normalizedHardwareBufferSize
        if remainder == 0 {
            return minimumFrames
        }
        return minimumFrames + (normalizedHardwareBufferSize - remainder)
    }
}

enum TrackChannelLayout: String, CaseIterable, Codable, Identifiable {
    case mono
    case stereo

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mono: "Mono"
        case .stereo: "Stereo"
        }
    }

    var channelCount: Int {
        switch self {
        case .mono: 1
        case .stereo: 2
        }
    }
}

struct MultiTrackLatencyBufferSettings: Codable, Hashable {
    var bufferedFrames: Int
    var broadcastFrames: Int
    var broadcastPrerollMultiplier: Int

    init(
        bufferedFrames: Int,
        broadcastFrames: Int,
        broadcastPrerollMultiplier: Int = DefaultBufferSizes.broadcastPrerollMultiplier
    ) {
        self.bufferedFrames = bufferedFrames
        self.broadcastFrames = broadcastFrames
        self.broadcastPrerollMultiplier = broadcastPrerollMultiplier
    }

    init(hardwareBufferSize: Int) {
        self.bufferedFrames = DefaultBufferSizes.preferredInternalBufferSize(
            defaultFrames: DefaultBufferSizes.bufferedFrames,
            hardwareBufferSize: hardwareBufferSize
        )
        self.broadcastFrames = DefaultBufferSizes.preferredInternalBufferSize(
            defaultFrames: DefaultBufferSizes.broadcastFrames,
            hardwareBufferSize: hardwareBufferSize
        )
        self.broadcastPrerollMultiplier = DefaultBufferSizes.broadcastPrerollMultiplier
    }

    private enum CodingKeys: String, CodingKey {
        case bufferedFrames
        case broadcastFrames
        case broadcastPrerollMultiplier
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bufferedFrames = try container.decode(Int.self, forKey: .bufferedFrames)
        broadcastFrames = try container.decode(Int.self, forKey: .broadcastFrames)
        broadcastPrerollMultiplier = try container.decodeIfPresent(
            Int.self,
            forKey: .broadcastPrerollMultiplier
        ) ?? DefaultBufferSizes.broadcastPrerollMultiplier
    }

    func internalFrames(
        for latencyClass: TrackLatencyClass,
        hardwareBufferSize: Int
    ) -> Int {
        switch latencyClass {
        case .realtime:
            hardwareBufferSize
        case .buffered:
            max(hardwareBufferSize, bufferedFrames)
        case .broadcast:
            max(hardwareBufferSize, broadcastFrames)
        }
    }
}

enum TrackLatencyClass: String, CaseIterable, Codable, Identifiable {
    case realtime
    case buffered
    case broadcast

    var id: String { rawValue }

    var title: String {
        switch self {
        case .realtime: "Realtime"
        case .buffered: "Buffered"
        case .broadcast: "Broadcast/Post"
        }
    }


    var description: String {
        switch self {
        case .realtime:
            "Lowest added latency. Runs directly on the hardware callback cadence."
        case .buffered:
            "Uses larger internal processing blocks with extra latency for heavier inserts."
        case .broadcast:
            "Largest internal processing blocks for non-critical post or broadcast paths."
        }
    }
}

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
}

struct MultiTrackTrackConfiguration: Identifiable, Codable, Hashable {
    struct PluginInsert: Identifiable, Codable, Hashable {
        let id: UUID
        var pluginID: String?
        var pluginStateData: Data?

        init(
            id: UUID = UUID(),
            pluginID: String? = nil,
            pluginStateData: Data? = nil
        ) {
            self.id = id
            self.pluginID = pluginID
            self.pluginStateData = pluginStateData
        }

        var hasPlugin: Bool {
            pluginID != nil
        }
    }

    let id: UUID
    var name: String
    var layout: TrackChannelLayout
    var inputStartChannel: Int
    var outputStartChannel: Int
    var latencyClass: TrackLatencyClass
    var wavesTuneStrength: WavesTuneStrengthPreset
    var plugins: [PluginInsert]
    var isEnabled: Bool

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case layout
        case inputStartChannel
        case outputStartChannel
        case latencyClass
        case wavesTuneStrength
        case plugins
        case isEnabled
    }

    init(
        id: UUID = UUID(),
        name: String,
        layout: TrackChannelLayout,
        inputStartChannel: Int = 1,
        outputStartChannel: Int = 1,
        latencyClass: TrackLatencyClass = .realtime,
        wavesTuneStrength: WavesTuneStrengthPreset = .standard,
        plugins: [PluginInsert] = [],
        isEnabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.layout = layout
        self.inputStartChannel = inputStartChannel
        self.outputStartChannel = outputStartChannel
        self.latencyClass = latencyClass
        self.wavesTuneStrength = wavesTuneStrength
        self.plugins = plugins
        self.isEnabled = isEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        layout = try container.decode(TrackChannelLayout.self, forKey: .layout)
        inputStartChannel = try container.decode(Int.self, forKey: .inputStartChannel)
        outputStartChannel = try container.decode(Int.self, forKey: .outputStartChannel)
        latencyClass = try container.decode(TrackLatencyClass.self, forKey: .latencyClass)
        wavesTuneStrength = try container.decodeIfPresent(WavesTuneStrengthPreset.self, forKey: .wavesTuneStrength) ?? .standard
        plugins = try container.decode([PluginInsert].self, forKey: .plugins)
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(layout, forKey: .layout)
        try container.encode(inputStartChannel, forKey: .inputStartChannel)
        try container.encode(outputStartChannel, forKey: .outputStartChannel)
        try container.encode(latencyClass, forKey: .latencyClass)
        try container.encode(wavesTuneStrength, forKey: .wavesTuneStrength)
        try container.encode(plugins, forKey: .plugins)
        try container.encode(isEnabled, forKey: .isEnabled)
    }

    var channelCount: Int {
        layout.channelCount
    }

    var hasPlugins: Bool {
        plugins.contains(where: \.hasPlugin)
    }

    var pluginCount: Int {
        plugins.count
    }
}

struct MultiTrackHostConfiguration {
    let inputDevice: AudioDeviceInfo
    let outputDevice: AudioDeviceInfo
    let bufferSize: Int
    let latencyBufferSettings: MultiTrackLatencyBufferSettings
    let tracks: [MultiTrackTrackConfiguration]
}

struct MultiTrackSessionFile: Codable {
    static let currentFormatVersion = 3

    var formatVersion: Int = currentFormatVersion
    var name: String
    var inputDeviceUID: String?
    var outputDeviceUID: String?
    var bufferSize: Int
    var latencyBufferSettings: MultiTrackLatencyBufferSettings
    var tracks: [MultiTrackTrackConfiguration]
    var wavesTuneState: MultiTrackWavesTuneState?

    func validateFormatVersion() throws {
        guard formatVersion <= Self.currentFormatVersion else {
            throw AudioHostError(
                "This session was saved with a newer version of SimpleAUHost (format \(formatVersion)). Update the app to open it."
            )
        }
    }
}

struct MultiTrackChainPresetFile: Codable {
    static let currentFormatVersion = 1

    var formatVersion: Int = currentFormatVersion
    var name: String
    var layout: TrackChannelLayout
    var plugins: [MultiTrackTrackConfiguration.PluginInsert]

    func validateFormatVersion() throws {
        guard formatVersion <= Self.currentFormatVersion else {
            throw AudioHostError(
                "This chain preset was saved with a newer version of SimpleAUHost (format \(formatVersion)). Update the app to open it."
            )
        }
    }
}

struct MultiTrackParameterPresetPluginState: Codable {
    var pluginID: String
    var pluginStateData: Data?
}

struct MultiTrackParameterPresetFile: Codable {
    static let currentFormatVersion = 1

    var formatVersion: Int = currentFormatVersion
    var name: String
    var plugins: [MultiTrackParameterPresetPluginState]

    func validateFormatVersion() throws {
        guard formatVersion <= Self.currentFormatVersion else {
            throw AudioHostError(
                "This parameter preset was saved with a newer version of SimpleAUHost (format \(formatVersion)). Update the app to open it."
            )
        }
    }
}

extension UTType {
    static let simpleAUHostMultiTrackSession = UTType(
        exportedAs: "dev.staubichsauger.simple-au-host.multi-track-session",
        conformingTo: .json
    )
}

struct MultiTrackSessionDocument: FileDocument {
    static var readableContentTypes: [UTType] {
        [.simpleAUHostMultiTrackSession, .json]
    }

    static var writableContentTypes: [UTType] {
        [.simpleAUHostMultiTrackSession]
    }

    var session: MultiTrackSessionFile

    init(session: MultiTrackSessionFile) {
        self.session = session
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw AudioHostError("The selected session file is empty.")
        }
        do {
            session = try JSONDecoder().decode(MultiTrackSessionFile.self, from: data)
        } catch {
            throw AudioHostError("Failed to read the multi-track session file: \(error.localizedDescription)")
        }
        try session.validateFormatVersion()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(session)
        return .init(regularFileWithContents: data)
    }
}
