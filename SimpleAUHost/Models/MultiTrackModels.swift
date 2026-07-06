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
