import Foundation
import SwiftUI
import UniformTypeIdentifiers

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

    init(
        bufferedFrames: Int,
        broadcastFrames: Int
    ) {
        self.bufferedFrames = bufferedFrames
        self.broadcastFrames = broadcastFrames
    }

    init(hardwareBufferSize: Int) {
        self.bufferedFrames = hardwareBufferSize * 4
        self.broadcastFrames = hardwareBufferSize * 8
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
    var plugins: [PluginInsert]
    var isEnabled: Bool

    init(
        id: UUID = UUID(),
        name: String,
        layout: TrackChannelLayout,
        inputStartChannel: Int = 1,
        outputStartChannel: Int = 1,
        latencyClass: TrackLatencyClass = .realtime,
        plugins: [PluginInsert] = [],
        isEnabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.layout = layout
        self.inputStartChannel = inputStartChannel
        self.outputStartChannel = outputStartChannel
        self.latencyClass = latencyClass
        self.plugins = plugins
        self.isEnabled = isEnabled
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
    var formatVersion: Int = 1
    var name: String
    var inputDeviceID: AudioDeviceID?
    var outputDeviceID: AudioDeviceID?
    var bufferSize: Int
    var latencyBufferSettings: MultiTrackLatencyBufferSettings
    var tracks: [MultiTrackTrackConfiguration]
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
            throw AudioHostError("Failed to read the multi-track session file.")
        }
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(session)
        return .init(regularFileWithContents: data)
    }
}
