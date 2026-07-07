import Foundation
import Network

enum CompanionControlDefaults {
    static let host = "127.0.0.1"
    static let port: UInt16 = 52719

    static var baseURLString: String {
        "http://\(host):\(port)"
    }

    static var allowedHostHeaderValues: Set<String> {
        [
            "\(host):\(port)",
            "localhost:\(port)"
        ]
    }
}

struct CompanionControlKeySnapshot: Codable, Sendable {
    let scaleMode: String
    let noteLetter: String
    let accidental: String
    let title: String
    let rootTitle: String

    init(selection: TuneKeySelection) {
        let normalized = selection.normalized
        scaleMode = normalized.scaleMode.rawValue
        noteLetter = normalized.noteLetter.rawValue
        accidental = normalized.accidental.rawValue
        title = normalized.title
        rootTitle = normalized.rootTitle
    }
}

struct CompanionControlTuneSnapshot: Codable, Sendable {
    let isEnabled: Bool
    let configuredInsertCount: Int
    let canApplyStagedKey: Bool
    let stagedKey: CompanionControlKeySnapshot
    let appliedKey: CompanionControlKeySnapshot
    let selectedSongTitle: String?
    let selectedSongIndex: Int?
    let songCount: Int
    let previousSongKey: CompanionControlKeySnapshot?
    let nextSongKey: CompanionControlKeySnapshot?
    let canSelectPreviousSong: Bool
    let canSelectNextSong: Bool
}

struct CompanionControlStateSnapshot: Codable, Sendable {
    let apiVersion: Int
    let appMode: String
    let timestamp: String
    let sessionName: String
    let statusMessage: String
    let isRunning: Bool
    let tune: CompanionControlTuneSnapshot
}

struct CompanionControlCommandResponse: Codable, Sendable {
    let ok: Bool
    let message: String
    let state: CompanionControlStateSnapshot
}

struct CompanionControlHealthResponse: Codable, Sendable {
    let ok: Bool
    let apiVersion: Int
    let appMode: String
}

struct CompanionControlBasicErrorResponse: Codable, Sendable {
    let ok: Bool
    let message: String
}

struct CompanionControlSetEnabledRequest: Decodable, Sendable {
    let enabled: Bool
}

struct CompanionControlSetStagedKeyRequest: Decodable, Sendable {
    let root: String
    let scaleMode: String
}

struct CompanionControlSetScaleModeRequest: Decodable, Sendable {
    let scaleMode: String
}

struct CompanionControlSetNoteLetterRequest: Decodable, Sendable {
    let noteLetter: String
}

struct CompanionControlSetAccidentalRequest: Decodable, Sendable {
    let accidental: String
}

struct CompanionControlStepSongRequest: Decodable, Sendable {
    let direction: Int
}

struct CompanionControlHTTPRequest: Sendable {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
}

struct CompanionControlHTTPResponse: Sendable {
    let statusCode: Int
    let headers: [String: String]
    let body: Data

    static func json<T: Encodable>(statusCode: Int, value: T) -> CompanionControlHTTPResponse {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let body = (try? encoder.encode(value)) ?? Data("{\"ok\":false,\"message\":\"Encoding failed.\"}".utf8)
        return CompanionControlHTTPResponse(
            statusCode: statusCode,
            headers: ["Content-Type": "application/json; charset=utf-8"],
            body: body
        )
    }
}

enum CompanionControlServerLifecycleState: Sendable {
    case starting(url: String)
    case listening(url: String)
    case failed(message: String)
    case stopped
}

final class CompanionControlServer: @unchecked Sendable {
    typealias RequestHandler = @Sendable (CompanionControlHTTPRequest) async -> CompanionControlHTTPResponse
    typealias StateHandler = @Sendable (CompanionControlServerLifecycleState) -> Void

    private let port: UInt16
    private let queue = DispatchQueue(label: "SimpleAUHost.CompanionControlServer")
    private var listener: NWListener?
    private var requestHandler: RequestHandler?
    private var stateHandler: StateHandler?
    private var activeSessions: [ObjectIdentifier: ConnectionSession] = [:]

    init(port: UInt16 = CompanionControlDefaults.port) {
        self.port = port
    }

    func start(
        requestHandler: @escaping RequestHandler,
        stateHandler: @escaping StateHandler
    ) throws {
        // All mutable server state (`listener`, the handlers, `activeSessions`)
        // is confined to `queue`: the connection callbacks and `stop()` mutate
        // it there. Hop onto the queue synchronously so `start()` keeps its
        // throwing signature. Must not be called from `queue` itself.
        try queue.sync {
            guard listener == nil else { return }

            self.requestHandler = requestHandler
            self.stateHandler = stateHandler

            let listenerPort = NWEndpoint.Port(rawValue: port)
            guard let listenerPort else {
                throw AudioHostError("The Companion control port is invalid.")
            }
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(
                host: NWEndpoint.Host(CompanionControlDefaults.host),
                port: listenerPort
            )

            let listener = try NWListener(using: parameters)
            self.listener = listener

            let url = CompanionControlDefaults.baseURLString
            stateHandler(.starting(url: url))

            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.stateHandler?(.listening(url: url))
                case .failed(let error):
                    self.stateHandler?(.failed(message: error.localizedDescription))
                case .cancelled:
                    self.stateHandler?(.stopped)
                default:
                    break
                }
            }

            listener.newConnectionHandler = { [weak self] connection in
                guard CompanionControlServer.isLoopbackConnection(connection) else {
                    connection.cancel()
                    return
                }

                guard let self, let requestHandler = self.requestHandler else {
                    connection.cancel()
                    return
                }

                let session = ConnectionSession(
                    connection: connection,
                    queue: self.queue,
                    requestHandler: requestHandler,
                    onClose: { [weak self] session in
                        self?.activeSessions.removeValue(forKey: ObjectIdentifier(session))
                    }
                )
                self.activeSessions[ObjectIdentifier(session)] = session
                session.start()
            }

            listener.start(queue: queue)
        }
    }

    func stop() {
        // Teardown runs on `queue` because the connection callbacks mutate the
        // same state there. `self` is captured strongly so the server survives
        // until teardown completes even if the owner releases it right after.
        queue.async {
            self.activeSessions.removeAll()
            self.listener?.cancel()
            self.listener = nil
            self.stateHandler?(.stopped)
            // Clearing the handlers after emitting `.stopped` releases the
            // owner's closures; the cancelled listener's late `.cancelled`
            // state update then finds no handler, avoiding a duplicate event.
            self.requestHandler = nil
            self.stateHandler = nil
        }
    }

    private static func isLoopbackConnection(_ connection: NWConnection) -> Bool {
        guard case .hostPort(let host, _) = connection.endpoint else {
            return false
        }

        switch host {
        case .ipv4(let address):
            return address.rawValue.first == 127
        case .ipv6(let address):
            return address.rawValue == Data(repeating: 0, count: 15) + Data([1])
        case .name(let name, _):
            return name.caseInsensitiveCompare("localhost") == .orderedSame
                || name == CompanionControlDefaults.host
                || name == "::1"
        @unknown default:
            return false
        }
    }
}

enum ParsedCompanionControlRequest {
    case incomplete
    case malformed(String)
    case tooLarge(String)
    case complete(CompanionControlHTTPRequest)
}

enum CompanionControlRequestParsingLimits {
    static let maximumHeaderBytes = 16 * 1024
    static let maximumBodyBytes = 256 * 1024
}

func parseCompanionControlHTTPRequest(
    from buffer: Data,
    maximumHeaderBytes: Int = CompanionControlRequestParsingLimits.maximumHeaderBytes,
    maximumBodyBytes: Int = CompanionControlRequestParsingLimits.maximumBodyBytes
) -> ParsedCompanionControlRequest {
    let delimiter = Data([13, 10, 13, 10])
    guard let headerRange = buffer.range(of: delimiter) else {
        if buffer.count > maximumHeaderBytes {
            return .tooLarge("Request headers are too large.")
        }
        return .incomplete
    }

    guard headerRange.lowerBound <= maximumHeaderBytes else {
        return .tooLarge("Request headers are too large.")
    }

    let headerData = buffer.subdata(in: 0..<headerRange.lowerBound)
    guard let headerText = String(data: headerData, encoding: .utf8) else {
        return .malformed("Request headers must be UTF-8.")
    }

    let lines = headerText.components(separatedBy: "\r\n")
    guard let requestLine = lines.first, !requestLine.isEmpty else {
        return .malformed("Missing request line.")
    }

    let requestLineParts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
    guard requestLineParts.count >= 2 else {
        return .malformed("Malformed request line.")
    }

    var headers: [String: String] = [:]
    for line in lines.dropFirst() where !line.isEmpty {
        let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else {
            return .malformed("Malformed header line.")
        }

        let name = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let value = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
        headers[name] = value
    }

    let bodyOffset = headerRange.upperBound
    let contentLength: Int
    if let rawContentLength = headers["content-length"] {
        guard let parsedContentLength = Int(rawContentLength), parsedContentLength >= 0 else {
            return .malformed("Content-Length must be a non-negative integer.")
        }
        contentLength = parsedContentLength
    } else {
        contentLength = 0
    }

    guard contentLength <= maximumBodyBytes else {
        return .tooLarge("Request body is too large.")
    }

    let totalLength = bodyOffset + contentLength
    guard totalLength <= maximumHeaderBytes + maximumBodyBytes else {
        return .tooLarge("Request is too large.")
    }

    guard buffer.count >= totalLength else {
        return .incomplete
    }

    let body = buffer.subdata(in: bodyOffset..<totalLength)
    return .complete(
        CompanionControlHTTPRequest(
            method: String(requestLineParts[0]).uppercased(),
            path: String(requestLineParts[1]),
            headers: headers,
            body: body
        )
    )
}

private final class ConnectionSession: @unchecked Sendable {
    private static let requestTimeout: DispatchTimeInterval = .seconds(5)

    private let connection: NWConnection
    private let queue: DispatchQueue
    private let requestHandler: CompanionControlServer.RequestHandler
    private let onClose: @Sendable (ConnectionSession) -> Void
    private var buffer = Data()
    private var hasClosed = false
    private var timeoutWorkItem: DispatchWorkItem?

    init(
        connection: NWConnection,
        queue: DispatchQueue,
        requestHandler: @escaping CompanionControlServer.RequestHandler,
        onClose: @escaping @Sendable (ConnectionSession) -> Void
    ) {
        self.connection = connection
        self.queue = queue
        self.requestHandler = requestHandler
        self.onClose = onClose
    }

    func start() {
        connection.start(queue: queue)
        scheduleTimeout()
        receiveNextChunk()
    }

    private func receiveNextChunk() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            guard !self.hasClosed else { return }

            if let data, !data.isEmpty {
                self.buffer.append(data)
            }

            if let error {
                self.send(
                    .json(
                        statusCode: 500,
                        value: CompanionControlBasicErrorResponse(
                            ok: false,
                            message: error.localizedDescription
                        )
                    )
                )
                return
            }

            switch parseCompanionControlHTTPRequest(from: self.buffer) {
            case .incomplete:
                if isComplete {
                    self.send(
                        .json(
                            statusCode: 400,
                            value: CompanionControlBasicErrorResponse(
                                ok: false,
                                message: "Incomplete HTTP request."
                            )
                        )
                    )
                } else {
                    self.receiveNextChunk()
                }
            case .malformed(let message):
                self.send(
                    .json(
                        statusCode: 400,
                        value: CompanionControlBasicErrorResponse(
                            ok: false,
                            message: message
                        )
                    )
                )
            case .tooLarge(let message):
                self.send(
                    .json(
                        statusCode: 413,
                        value: CompanionControlBasicErrorResponse(
                            ok: false,
                            message: message
                        )
                    )
                )
            case .complete(let request):
                self.cancelTimeout()
                let requestHandler = self.requestHandler
                let queue = self.queue
                Task {
                    let response = await requestHandler(request)
                    queue.async { [weak self] in
                        self?.send(response)
                    }
                }
            }
        }
    }

    private func send(_ response: CompanionControlHTTPResponse) {
        guard !hasClosed else { return }
        var headerLines = [
            "HTTP/1.1 \(response.statusCode) \(reasonPhrase(for: response.statusCode))",
            "Content-Length: \(response.body.count)",
            "Connection: close"
        ]

        let responseHeaders = response.headers.sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
        for (name, value) in responseHeaders {
            headerLines.append("\(name): \(value)")
        }

        var data = Data((headerLines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        data.append(response.body)

        connection.send(content: data, completion: .contentProcessed { [weak self] _ in
            self?.finish()
        })
    }

    private func finish() {
        guard !hasClosed else { return }
        hasClosed = true
        cancelTimeout()
        connection.cancel()
        onClose(self)
    }

    private func scheduleTimeout() {
        let timeoutWorkItem = DispatchWorkItem { [weak self] in
            guard let self, !self.hasClosed else { return }
            self.send(
                .json(
                    statusCode: 408,
                    value: CompanionControlBasicErrorResponse(
                        ok: false,
                        message: "Request timed out."
                    )
                )
            )
        }
        self.timeoutWorkItem = timeoutWorkItem
        queue.asyncAfter(deadline: .now() + Self.requestTimeout, execute: timeoutWorkItem)
    }

    private func cancelTimeout() {
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
    }

    private func reasonPhrase(for statusCode: Int) -> String {
        switch statusCode {
        case 200: "OK"
        case 400: "Bad Request"
        case 408: "Request Timeout"
        case 413: "Content Too Large"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 500: "Internal Server Error"
        case 503: "Service Unavailable"
        default: "HTTP Response"
        }
    }
}
