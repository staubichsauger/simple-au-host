import XCTest
@testable import SimpleAUHost

final class CompanionControlParserTests: XCTestCase {
    func testParseCompleteGetRequest() {
        let data = Data("GET /api/v1/state HTTP/1.1\r\nHost: 127.0.0.1:52719\r\n\r\n".utf8)

        guard case .complete(let request) = parseCompanionControlHTTPRequest(from: data) else {
            return XCTFail("Expected a complete request.")
        }

        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.path, "/api/v1/state")
        XCTAssertEqual(request.headers["host"], "127.0.0.1:52719")
        XCTAssertTrue(request.body.isEmpty)
    }

    func testParseCompletePostRequestWithBody() {
        let body = #"{"enabled":true}"#
        let rawRequest = """
        POST /api/v1/actions/waves-tune/enabled HTTP/1.1\r
        Host: localhost:52719\r
        Content-Type: application/json; charset=utf-8\r
        Content-Length: \(Data(body.utf8).count)\r
        \r
        \(body)
        """

        guard case .complete(let request) = parseCompanionControlHTTPRequest(from: Data(rawRequest.utf8)) else {
            return XCTFail("Expected a complete request.")
        }

        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/api/v1/actions/waves-tune/enabled")
        XCTAssertEqual(request.headers["content-type"], "application/json; charset=utf-8")
        XCTAssertEqual(String(data: request.body, encoding: .utf8), body)
    }

    func testParseRequestReturnsIncompleteUntilHeaderDelimiterArrives() {
        let data = Data("GET /health HTTP/1.1\r\nHost: localhost:52719".utf8)

        guard case .incomplete = parseCompanionControlHTTPRequest(from: data) else {
            return XCTFail("Expected an incomplete request.")
        }
    }

    func testParseRequestReturnsIncompleteUntilDeclaredBodyArrives() {
        let body = #"{"enabled":true}"#
        let partialBody = #"{"enabled""#
        let rawRequest = """
        POST /api/v1/actions/waves-tune/enabled HTTP/1.1\r
        Host: localhost:52719\r
        Content-Length: \(Data(body.utf8).count)\r
        \r
        \(partialBody)
        """

        guard case .incomplete = parseCompanionControlHTTPRequest(from: Data(rawRequest.utf8)) else {
            return XCTFail("Expected an incomplete request.")
        }
    }

    func testParseRequestRejectsMalformedHeaderLine() {
        let data = Data("GET /health HTTP/1.1\r\nBad Header\r\n\r\n".utf8)

        guard case .malformed(let message) = parseCompanionControlHTTPRequest(from: data) else {
            return XCTFail("Expected a malformed request.")
        }

        XCTAssertEqual(message, "Malformed header line.")
    }

    func testParseRequestRejectsInvalidContentLength() {
        let data = Data("POST /api/v1/state HTTP/1.1\r\nContent-Length: nope\r\n\r\n".utf8)

        guard case .malformed(let message) = parseCompanionControlHTTPRequest(from: data) else {
            return XCTFail("Expected a malformed request.")
        }

        XCTAssertEqual(message, "Content-Length must be a non-negative integer.")
    }

    func testParseRequestRejectsOversizedHeadersAndBodies() {
        let headerData = Data("GET /health HTTP/1.1\r\nHeader: value\r\n\r\n".utf8)
        guard case .tooLarge(let headerMessage) = parseCompanionControlHTTPRequest(
            from: headerData,
            maximumHeaderBytes: 8,
            maximumBodyBytes: 256
        ) else {
            return XCTFail("Expected oversized headers.")
        }

        XCTAssertEqual(headerMessage, "Request headers are too large.")

        let bodyData = Data(
            """
            POST /api/v1/state HTTP/1.1\r
            Content-Length: 3\r
            \r
            abc
            """.utf8
        )
        guard case .tooLarge(let bodyMessage) = parseCompanionControlHTTPRequest(
            from: bodyData,
            maximumHeaderBytes: 1_024,
            maximumBodyBytes: 2
        ) else {
            return XCTFail("Expected oversized body.")
        }

        XCTAssertEqual(bodyMessage, "Request body is too large.")
    }
}
