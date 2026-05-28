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

}
