import XCTest
@testable import SimpleAUHost

final class SessionStoreTests: XCTestCase {
    func testManagedSessionsOnlyListsSessionFiles() throws {
        let fileManager = FileManager.default
        let sessions = try SAHManagedSessionStore.sessionsDirectoryURL(fileManager: fileManager)
        let suffix = UUID().uuidString
        let validSession = sessions.appendingPathComponent("UnitTest-\(suffix).sahsession")
        let ignoredFile = sessions.appendingPathComponent("UnitTest-\(suffix).txt")
        let ignoredDirectory = sessions.appendingPathComponent("UnitTest-\(suffix)-Folder.sahsession", isDirectory: true)
        defer {
            try? fileManager.removeItem(at: validSession)
            try? fileManager.removeItem(at: ignoredFile)
            try? fileManager.removeItem(at: ignoredDirectory)
        }
        try Data("{}".utf8).write(to: validSession)
        try Data("{}".utf8).write(to: ignoredFile)
        try fileManager.createDirectory(at: ignoredDirectory, withIntermediateDirectories: true)

        let managedSessions = try SAHManagedSessionStore.managedSessions(fileManager: fileManager)
        let managedNames = Set(managedSessions.map(\.url.lastPathComponent))

        XCTAssertTrue(managedNames.contains(validSession.lastPathComponent))
        XCTAssertFalse(managedNames.contains(ignoredFile.lastPathComponent))
        XCTAssertFalse(managedNames.contains(ignoredDirectory.lastPathComponent))
    }

    func testWavesTuneSongNotesDecodeAsEmptyForOlderFiles() throws {
        let json = """
        {
          "id": "00000000-0000-0000-0000-000000000001",
          "title": "Song",
          "key": {
            "scaleMode": "major",
            "noteLetter": "c",
            "accidental": "natural"
          }
        }
        """

        let song = try JSONDecoder().decode(WavesTuneSongEntry.self, from: Data(json.utf8))

        XCTAssertEqual(song.notes, "")
        XCTAssertEqual(song.key.title, "C Major")
    }

    func testLatencyBufferSettingsDecodeBroadcastPrerollAsOneForOlderFiles() throws {
        let json = """
        {
          "bufferedFrames": 128,
          "broadcastFrames": 512
        }
        """

        let settings = try JSONDecoder().decode(MultiTrackLatencyBufferSettings.self, from: Data(json.utf8))

        XCTAssertEqual(settings.bufferedFrames, 128)
        XCTAssertEqual(settings.broadcastFrames, 512)
        XCTAssertEqual(settings.broadcastPrerollMultiplier, 1)
    }

    func testSessionFileRejectsFutureFormatVersion() throws {
        var session = MultiTrackSessionFile(
            name: "Future",
            inputDeviceUID: nil,
            outputDeviceUID: nil,
            bufferSize: 128,
            latencyBufferSettings: .init(bufferedFrames: 256, broadcastFrames: 512),
            tracks: [],
            wavesTuneState: nil
        )
        session.formatVersion = MultiTrackSessionFile.currentFormatVersion + 1

        XCTAssertThrowsError(try session.validateFormatVersion()) { error in
            XCTAssertTrue(error.localizedDescription.contains("newer version of SimpleAUHost"))
        }
    }

    func testPresetFilesRejectFutureFormatVersion() throws {
        var chainPreset = MultiTrackChainPresetFile(
            name: "Future Chain",
            layout: .mono,
            plugins: []
        )
        chainPreset.formatVersion = MultiTrackChainPresetFile.currentFormatVersion + 1

        XCTAssertThrowsError(try chainPreset.validateFormatVersion()) { error in
            XCTAssertTrue(error.localizedDescription.contains("newer version of SimpleAUHost"))
        }

        var parameterPreset = MultiTrackParameterPresetFile(
            name: "Future Params",
            plugins: []
        )
        parameterPreset.formatVersion = MultiTrackParameterPresetFile.currentFormatVersion + 1

        XCTAssertThrowsError(try parameterPreset.validateFormatVersion()) { error in
            XCTAssertTrue(error.localizedDescription.contains("newer version of SimpleAUHost"))
        }
    }

    func testCurrentFormatVersionsAreDefaulted() throws {
        let session = MultiTrackSessionFile(
            name: "Current",
            inputDeviceUID: nil,
            outputDeviceUID: nil,
            bufferSize: 128,
            latencyBufferSettings: .init(bufferedFrames: 256, broadcastFrames: 512),
            tracks: [],
            wavesTuneState: nil
        )
        let chainPreset = MultiTrackChainPresetFile(
            name: "Current Chain",
            layout: .mono,
            plugins: []
        )
        let parameterPreset = MultiTrackParameterPresetFile(
            name: "Current Params",
            plugins: []
        )

        XCTAssertEqual(session.formatVersion, MultiTrackSessionFile.currentFormatVersion)
        XCTAssertEqual(chainPreset.formatVersion, MultiTrackChainPresetFile.currentFormatVersion)
        XCTAssertEqual(parameterPreset.formatVersion, MultiTrackParameterPresetFile.currentFormatVersion)
    }
}
