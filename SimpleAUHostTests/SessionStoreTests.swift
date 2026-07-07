import XCTest
@testable import SimpleAUHost

final class SessionStoreTests: XCTestCase {
    private var temporaryRoots: [URL] = []

    override func tearDownWithError() throws {
        let roots = temporaryRoots
        temporaryRoots = []
        for root in roots {
            try? FileManager.default.removeItem(at: root)
        }
        try super.tearDownWithError()
    }

    func testManagedSessionsOnlyListsSessionFiles() throws {
        let fileManager = FileManager.default
        let root = makeTemporaryManagedStorageRoot()
        let sessions = try SAHManagedSessionStore.sessionsDirectoryURL(
            rootDirectoryURL: root,
            fileManager: fileManager
        )
        let suffix = UUID().uuidString
        let validSession = sessions.appendingPathComponent("UnitTest-\(suffix).sahsession")
        let ignoredFile = sessions.appendingPathComponent("UnitTest-\(suffix).txt")
        let ignoredDirectory = sessions.appendingPathComponent("UnitTest-\(suffix)-Folder.sahsession", isDirectory: true)
        try Data("{}".utf8).write(to: validSession)
        try Data("{}".utf8).write(to: ignoredFile)
        try fileManager.createDirectory(at: ignoredDirectory, withIntermediateDirectories: true)

        let managedSessions = try SAHManagedSessionStore.managedSessions(
            rootDirectoryURL: root,
            fileManager: fileManager
        )
        let managedNames = Set(managedSessions.map(\.url.lastPathComponent))

        XCTAssertTrue(managedNames.contains(validSession.lastPathComponent))
        XCTAssertFalse(managedNames.contains(ignoredFile.lastPathComponent))
        XCTAssertFalse(managedNames.contains(ignoredDirectory.lastPathComponent))
    }

    func testTuneSongNotesDecodeAsEmptyForOlderFiles() throws {
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

        let song = try JSONDecoder().decode(TuneSongEntry.self, from: Data(json.utf8))

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
            tuneState: nil
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
            tuneState: nil
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
        XCTAssertEqual(MultiTrackSessionFile.currentFormatVersion, 4)
        XCTAssertEqual(chainPreset.formatVersion, MultiTrackChainPresetFile.currentFormatVersion)
        XCTAssertEqual(parameterPreset.formatVersion, MultiTrackParameterPresetFile.currentFormatVersion)
    }

    func testAtomicCounterOperations() {
        let counter = AtomicCounter()
        XCTAssertEqual(counter.load(), 0)

        counter.increment()
        counter.add(41)
        XCTAssertEqual(counter.load(), 42)

        counter.storeMax(10)
        XCTAssertEqual(counter.load(), 42)
        counter.storeMax(100)
        XCTAssertEqual(counter.load(), 100)

        counter.reset()
        XCTAssertEqual(counter.load(), 0)
    }

    func testFloatRingBufferRoundTripAndWraparound() {
        let ring = FloatRingBuffer()
        XCTAssertTrue(ring.initialize(minimumCapacity: 60))
        XCTAssertEqual(ring.capacity, 64)
        XCTAssertEqual(ring.availableRead(), 0)
        XCTAssertEqual(ring.availableWrite(), 64)

        var input: [Float] = (0..<48).map(Float.init)
        var output = [Float](repeating: -1, count: 48)

        XCTAssertEqual(input.withUnsafeBufferPointer { ring.write(from: $0.baseAddress!, count: 48) }, 48)
        XCTAssertEqual(ring.availableRead(), 48)
        XCTAssertEqual(output.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, count: 48) }, 48)
        XCTAssertEqual(output, input)

        // Second pass wraps around the end of storage.
        input = (100..<148).map(Float.init)
        XCTAssertEqual(input.withUnsafeBufferPointer { ring.write(from: $0.baseAddress!, count: 48) }, 48)

        // An overflowing write is truncated to the remaining space.
        let extra: [Float] = (0..<32).map(Float.init)
        XCTAssertEqual(extra.withUnsafeBufferPointer { ring.write(from: $0.baseAddress!, count: 32) }, 16)

        XCTAssertEqual(output.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, count: 48) }, 48)
        XCTAssertEqual(output, input)
    }

    func testFloatRingBufferSingleProducerSingleConsumerIntegrity() {
        let ring = FloatRingBuffer()
        XCTAssertTrue(ring.initialize(minimumCapacity: 1024))

        let totalSamples = 1 << 18
        let chunk = 240
        let producerDone = expectation(description: "producer finished")
        let consumerDone = expectation(description: "consumer finished")

        DispatchQueue.global(qos: .userInitiated).async {
            var next = 0
            var buffer = [Float](repeating: 0, count: chunk)
            while next < totalSamples {
                let count = min(chunk, totalSamples - next)
                for index in 0..<count {
                    buffer[index] = Float(next + index)
                }
                let written = buffer.withUnsafeBufferPointer {
                    ring.write(from: $0.baseAddress!, count: UInt32(count))
                }
                next += Int(written)
                if written == 0 {
                    sched_yield()
                }
            }
            producerDone.fulfill()
        }

        DispatchQueue.global(qos: .userInitiated).async {
            var next = 0
            var corrupted = false
            var buffer = [Float](repeating: 0, count: chunk)
            while next < totalSamples {
                let requested = min(chunk, totalSamples - next)
                let read = buffer.withUnsafeMutableBufferPointer {
                    ring.read(into: $0.baseAddress!, count: UInt32(requested))
                }
                if read == 0 {
                    sched_yield()
                    continue
                }
                for index in 0..<Int(read) where buffer[index] != Float(next + index) {
                    corrupted = true
                }
                next += Int(read)
            }
            XCTAssertFalse(corrupted, "Ring buffer lost, duplicated, or reordered samples")
            consumerDone.fulfill()
        }

        wait(for: [producerDone, consumerDone], timeout: 30)
    }

    private func makeTemporaryManagedStorageRoot() -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SimpleAUHostTests-\(UUID().uuidString)",
            isDirectory: true
        )
        temporaryRoots.append(root)
        return root
    }
}
