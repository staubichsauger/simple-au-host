import XCTest
@testable import SimpleAUHost

final class MultiTrackValidationTests: XCTestCase {
    func testSanitizedTrackClampsInputAndOutputStartsToAvailableDeviceChannels() {
        let track = MultiTrackTrackConfiguration(
            name: "Stereo",
            layout: .stereo,
            inputStartChannel: 99,
            outputStartChannel: 0
        )

        let sanitized = MultiTrackValidation.sanitizedTrack(
            track,
            inputDevice: makeDevice(inputChannels: 4, outputChannels: 0),
            outputDevice: makeDevice(inputChannels: 0, outputChannels: 6)
        )

        XCTAssertEqual(sanitized.inputStartChannel, 3)
        XCTAssertEqual(sanitized.outputStartChannel, 1)
    }

    func testSanitizedTrackFallsBackToChannelOneWhenDevicesAreMissing() {
        let track = MultiTrackTrackConfiguration(
            name: "Track",
            layout: .mono,
            inputStartChannel: 8,
            outputStartChannel: 9
        )

        let sanitized = MultiTrackValidation.sanitizedTrack(
            track,
            inputDevice: nil,
            outputDevice: nil
        )

        XCTAssertEqual(sanitized.inputStartChannel, 1)
        XCTAssertEqual(sanitized.outputStartChannel, 1)
    }

    func testValidateExclusiveOutputRoutingRejectsOverlappingEnabledTracks() {
        let tracks = [
            MultiTrackTrackConfiguration(name: "Lead", layout: .stereo, outputStartChannel: 1),
            MultiTrackTrackConfiguration(name: "BGV", layout: .mono, outputStartChannel: 2)
        ]

        let error = MultiTrackValidation.validateExclusiveOutputRouting(for: tracks)

        XCTAssertEqual(error, "BGV conflicts with Lead on output channel 2. Outputs are exclusive.")
    }

    func testOutputChannelsAreAvailableIgnoresDisabledTracks() {
        let activeTrack = MultiTrackTrackConfiguration(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            name: "Active",
            layout: .stereo,
            outputStartChannel: 3
        )
        let disabledTrack = MultiTrackTrackConfiguration(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            name: "Disabled",
            layout: .stereo,
            outputStartChannel: 1,
            isEnabled: false
        )
        let proposedTrack = MultiTrackTrackConfiguration(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
            name: "Proposed",
            layout: .stereo
        )

        XCTAssertTrue(
            MultiTrackValidation.outputChannelsAreAvailable(
                for: proposedTrack,
                proposedStartChannel: 1,
                tracks: [activeTrack, disabledTrack, proposedTrack]
            )
        )
        XCTAssertFalse(
            MultiTrackValidation.outputChannelsAreAvailable(
                for: proposedTrack,
                proposedStartChannel: 4,
                tracks: [activeTrack, disabledTrack, proposedTrack]
            )
        )
    }

    func testValidateLatencyBufferTextRequiresNumericHardwareMultipleWithinBounds() {
        XCTAssertNil(
            MultiTrackValidation.validateLatencyBufferText(
                "128",
                for: .buffered,
                hardwareBufferSize: 64
            )
        )
        XCTAssertEqual(
            MultiTrackValidation.validateLatencyBufferText(
                "abc",
                for: .buffered,
                hardwareBufferSize: 64
            ),
            "Buffered internal buffer must be numeric."
        )
        XCTAssertEqual(
            MultiTrackValidation.validateLatencyBufferText(
                "32",
                for: .buffered,
                hardwareBufferSize: 64
            ),
            "Buffered internal buffer must be at least the hardware buffer size."
        )
        XCTAssertEqual(
            MultiTrackValidation.validateLatencyBufferText(
                "96",
                for: .buffered,
                hardwareBufferSize: 64
            ),
            "Buffered internal buffer must be a whole multiple of the hardware buffer size."
        )
        XCTAssertEqual(
            MultiTrackValidation.validateLatencyBufferText(
                "20000",
                for: .buffered,
                hardwareBufferSize: 64
            ),
            "Buffered internal buffer must not exceed 16384 frames."
        )
    }

    func testNormalizedInternalBufferSizeClampsAndRoundsToHardwareMultiple() {
        XCTAssertEqual(
            MultiTrackValidation.normalizedInternalBufferSize(1, hardwareBufferSize: 64),
            64
        )
        XCTAssertEqual(
            MultiTrackValidation.normalizedInternalBufferSize(65, hardwareBufferSize: 64),
            128
        )
        XCTAssertEqual(
            MultiTrackValidation.normalizedInternalBufferSize(20_000, hardwareBufferSize: 64),
            16_384
        )
    }

    func testValidateTrackRejectsUnavailablePluginIDs() {
        let track = MultiTrackTrackConfiguration(
            name: "Lead",
            layout: .mono,
            plugins: [.init(pluginID: "missing")]
        )

        let error = MultiTrackValidation.validateTrack(
            track,
            inputDevice: makeDevice(inputChannels: 2, outputChannels: 0),
            outputDevice: makeDevice(inputChannels: 0, outputChannels: 2),
            availablePluginIDs: []
        )

        XCTAssertEqual(
            error,
            "Lead references a plugin that is not currently installed. Install it or choose Bypass."
        )
    }

    private func makeDevice(
        inputChannels: Int,
        outputChannels: Int
    ) -> AudioDeviceInfo {
        AudioDeviceInfo(
            id: 1,
            uid: UUID().uuidString,
            name: "Unit Test Device",
            inputChannelCount: inputChannels,
            outputChannelCount: outputChannels,
            nominalSampleRate: 48_000,
            currentBufferSize: 64,
            bufferSizeRange: 32...512
        )
    }
}
