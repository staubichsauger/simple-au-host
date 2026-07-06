import Foundation

enum MultiTrackValidation {
    static func normalizedBroadcastPrerollMultiplier(_ value: Int) -> Int {
        min(max(value, 1), 3)
    }

    static func normalizedInternalBufferSize(_ value: Int, hardwareBufferSize: Int) -> Int {
        let minimum = max(1, hardwareBufferSize)
        let maximum = 16_384
        let clamped = min(max(value, minimum), maximum)
        let remainder = clamped % minimum
        if remainder == 0 {
            return clamped
        }
        return min(clamped + (minimum - remainder), maximum)
    }

    static func validateLatencyBufferText(
        _ text: String,
        for latencyClass: TrackLatencyClass,
        hardwareBufferSize: Int
    ) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(trimmed) else {
            return "\(latencyClass.title) internal buffer must be numeric."
        }

        guard value >= hardwareBufferSize else {
            return "\(latencyClass.title) internal buffer must be at least the hardware buffer size."
        }

        guard value <= 16_384 else {
            return "\(latencyClass.title) internal buffer must not exceed 16384 frames."
        }

        guard value % hardwareBufferSize == 0 else {
            return "\(latencyClass.title) internal buffer must be a whole multiple of the hardware buffer size."
        }

        return nil
    }

    static func sanitizedTrack(
        _ track: MultiTrackTrackConfiguration,
        inputDevice: AudioDeviceInfo?,
        outputDevice: AudioDeviceInfo?
    ) -> MultiTrackTrackConfiguration {
        var track = track
        if let inputDevice {
            let maxStart = max(1, inputDevice.inputChannelCount - track.channelCount + 1)
            track.inputStartChannel = min(max(1, track.inputStartChannel), maxStart)
        } else {
            track.inputStartChannel = 1
        }

        if let outputDevice {
            let maxStart = max(1, outputDevice.outputChannelCount - track.channelCount + 1)
            track.outputStartChannel = min(max(1, track.outputStartChannel), maxStart)
        } else {
            track.outputStartChannel = 1
        }

        return track
    }

    static func validateTrack(
        _ track: MultiTrackTrackConfiguration,
        inputDevice: AudioDeviceInfo?,
        outputDevice: AudioDeviceInfo?,
        availablePluginIDs: Set<String>
    ) -> String? {
        guard track.isEnabled else { return nil }
        guard let inputDevice, let outputDevice else {
            return "Select both devices before starting multi track mode."
        }

        guard !track.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Every enabled track needs a name."
        }

        let requiredInputChannels = track.inputStartChannel + track.channelCount - 1
        guard requiredInputChannels <= inputDevice.inputChannelCount else {
            return "\(track.name) exceeds the selected input interface channel count."
        }

        let requiredOutputChannels = track.outputStartChannel + track.channelCount - 1
        guard requiredOutputChannels <= outputDevice.outputChannelCount else {
            return "\(track.name) exceeds the selected output interface channel count."
        }

        for insert in track.plugins {
            if let pluginID = insert.pluginID, !availablePluginIDs.contains(pluginID) {
                return "\(track.name) references a plugin that is not currently installed. Install it or choose Bypass."
            }
        }

        return nil
    }

    static func validateExclusiveOutputRouting(
        for tracks: [MultiTrackTrackConfiguration]
    ) -> String? {
        var channelOwners: [Int: String] = [:]

        for track in tracks where track.isEnabled {
            let outputChannels = track.outputStartChannel..<(track.outputStartChannel + track.channelCount)
            for channel in outputChannels {
                if let existingOwner = channelOwners[channel] {
                    return "\(track.name) conflicts with \(existingOwner) on output channel \(channel). Outputs are exclusive."
                }
                channelOwners[channel] = track.name
            }
        }

        return nil
    }

    static func outputChannelsAreAvailable(
        for track: MultiTrackTrackConfiguration,
        proposedStartChannel: Int,
        tracks: [MultiTrackTrackConfiguration]
    ) -> Bool {
        let proposedRange = proposedStartChannel..<(proposedStartChannel + track.channelCount)

        for otherTrack in tracks where otherTrack.id != track.id && otherTrack.isEnabled {
            let otherRange = otherTrack.outputStartChannel..<(otherTrack.outputStartChannel + otherTrack.channelCount)
            if proposedRange.overlaps(otherRange) {
                return false
            }
        }

        return true
    }
}
