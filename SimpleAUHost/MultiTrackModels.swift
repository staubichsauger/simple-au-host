import Foundation

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
    let id: UUID
    var name: String
    var layout: TrackChannelLayout
    var inputStartChannel: Int
    var outputStartChannel: Int
    var latencyClass: TrackLatencyClass
    var pluginID: String?
    var isEnabled: Bool

    init(
        id: UUID = UUID(),
        name: String,
        layout: TrackChannelLayout,
        inputStartChannel: Int = 1,
        outputStartChannel: Int = 1,
        latencyClass: TrackLatencyClass = .realtime,
        pluginID: String? = nil,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.layout = layout
        self.inputStartChannel = inputStartChannel
        self.outputStartChannel = outputStartChannel
        self.latencyClass = latencyClass
        self.pluginID = pluginID
        self.isEnabled = isEnabled
    }

    var channelCount: Int {
        layout.channelCount
    }
}

struct MultiTrackHostConfiguration {
    let inputDevice: AudioDeviceInfo
    let outputDevice: AudioDeviceInfo
    let bufferSize: Int
    let latencyBufferSettings: MultiTrackLatencyBufferSettings
    let tracks: [MultiTrackTrackConfiguration]
}
