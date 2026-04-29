import XCTest
@testable import NewsCombApp

final class MCPWorkspaceValidatorTests: XCTestCase {

    private let workspaceA = URL(filePath: "/tmp/workspaces/A").canonicalDirectoryURL
    private let workspaceB = URL(filePath: "/tmp/workspaces/B").canonicalDirectoryURL

    // MARK: - Allow paths

    func testAllowsRequestWithNoHeader() {
        let result = MCPWorkspaceValidator.validate(requestedHeader: nil, active: workspaceA)
        XCTAssertNil(result)
    }

    func testAllowsRequestWithEmptyHeader() {
        let result = MCPWorkspaceValidator.validate(requestedHeader: "", active: workspaceA)
        XCTAssertNil(result)
    }

    func testAllowsMatchingHeader() {
        let result = MCPWorkspaceValidator.validate(
            requestedHeader: workspaceA.path(percentEncoded: false),
            active: workspaceA
        )
        XCTAssertNil(result)
    }

    func testAllowsMatchingHeaderIgnoringTrailingSlash() {
        let result = MCPWorkspaceValidator.validate(
            requestedHeader: workspaceA.path(percentEncoded: false) + "/",
            active: workspaceA
        )
        XCTAssertNil(result)
    }

    // MARK: - Reject paths

    func testRejectsHeaderWhenNoActiveWorkspace() {
        let result = MCPWorkspaceValidator.validate(
            requestedHeader: workspaceA.path(percentEncoded: false),
            active: nil
        )
        guard case let .noActiveWorkspace(requested) = result else {
            return XCTFail("Expected .noActiveWorkspace, got \(String(describing: result))")
        }
        XCTAssertEqual(requested, workspaceA)
    }

    func testRejectsMismatchedHeader() {
        let result = MCPWorkspaceValidator.validate(
            requestedHeader: workspaceB.path(percentEncoded: false),
            active: workspaceA
        )
        guard case let .mismatch(active, requested) = result else {
            return XCTFail("Expected .mismatch, got \(String(describing: result))")
        }
        XCTAssertEqual(active, workspaceA)
        XCTAssertEqual(requested, workspaceB)
    }

    // MARK: - Error formatting

    func testNoActiveWorkspaceMessageMentionsRequested() {
        let result = MCPWorkspaceValidator.validate(
            requestedHeader: workspaceA.path(percentEncoded: false),
            active: nil
        )
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.message.contains(workspaceA.path(percentEncoded: false)))
    }

    func testMismatchMessageMentionsBothPaths() {
        let result = MCPWorkspaceValidator.validate(
            requestedHeader: workspaceB.path(percentEncoded: false),
            active: workspaceA
        )
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.message.contains(workspaceA.path(percentEncoded: false)))
        XCTAssertTrue(result!.message.contains(workspaceB.path(percentEncoded: false)))
    }

    func testFailureCodeIsServerDefined() {
        let result = MCPWorkspaceValidator.validate(
            requestedHeader: workspaceB.path(percentEncoded: false),
            active: workspaceA
        )
        XCTAssertEqual(result?.code, -32001)
    }

    // MARK: - JSON-RPC error response formatting

    func testMakeJSONRPCErrorBodyHasJSONRPCField() throws {
        let data = MCPHTTPServer.makeJSONRPCErrorHTTPResponse(
            requestId: "abc",
            code: -32001,
            message: "boom"
        )
        let httpString = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(httpString.contains("HTTP/1.1 400"))
        XCTAssertTrue(httpString.contains("Content-Type: application/json"))
        XCTAssertTrue(httpString.contains("\"jsonrpc\":\"2.0\""))
        XCTAssertTrue(httpString.contains("\"id\":\"abc\""))
        XCTAssertTrue(httpString.contains("\"code\":-32001"))
        XCTAssertTrue(httpString.contains("\"message\":\"boom\""))
    }

    func testMakeJSONRPCErrorBodyEscapesQuotesInMessage() {
        let data = MCPHTTPServer.makeJSONRPCErrorHTTPResponse(
            requestId: nil,
            code: -32001,
            message: "has \"quotes\" and \\ backslash"
        )
        let httpString = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(httpString.contains("\\\"quotes\\\""))
        XCTAssertTrue(httpString.contains("\\\\ backslash"))
    }

    /// Regression test for the previous hand-rolled escaper, which only
    /// handled `\\` and `"` and produced invalid JSON when the message
    /// contained newlines, tabs, or other C0 control characters.
    func testMakeJSONRPCErrorBodyRoundTripsControlCharactersAsValidJSON() throws {
        let message = "line one\nline two\twith tab\u{0001}and ctrl"
        let data = MCPHTTPServer.makeJSONRPCErrorHTTPResponse(
            requestId: "req-1",
            code: -32001,
            message: message
        )
        let body = try Self.extractBody(from: data)
        let parsed = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any],
            "Body must parse as a JSON object"
        )
        let errorObj = try XCTUnwrap(parsed["error"] as? [String: Any])
        XCTAssertEqual(errorObj["message"] as? String, message)
        XCTAssertEqual(errorObj["code"] as? Int, -32001)
        XCTAssertEqual(parsed["id"] as? String, "req-1")
        XCTAssertEqual(parsed["jsonrpc"] as? String, "2.0")
    }

    func testMakeJSONRPCErrorBodyEncodesNullIdWhenRequestIdMissing() throws {
        let data = MCPHTTPServer.makeJSONRPCErrorHTTPResponse(
            requestId: nil,
            code: -32001,
            message: "boom"
        )
        let body = try Self.extractBody(from: data)
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        // JSON-RPC spec: when the id can't be determined, it must be encoded
        // as the JSON literal `null`, not the string "null".
        XCTAssertTrue(parsed["id"] is NSNull, "Missing requestId must serialize as JSON null")
    }

    /// Splits the raw HTTP/1.1 response into headers + body and returns the body bytes.
    /// Locates `\r\n\r\n` by byte search so the offset is correct in `Data` even
    /// if the body contains non-ASCII bytes.
    private static func extractBody(from data: Data) throws -> Data {
        let separator: [UInt8] = [0x0D, 0x0A, 0x0D, 0x0A]
        guard let range = data.range(of: Data(separator)) else {
            throw NSError(
                domain: "MCPWorkspaceValidatorTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "No CRLF CRLF separator found in response"]
            )
        }
        return data.subdata(in: range.upperBound..<data.endIndex)
    }

    func testExtractRequestIdFromStringId() {
        let body = Data(#"{"jsonrpc":"2.0","id":"req-42","method":"tools/list"}"#.utf8)
        XCTAssertEqual(MCPHTTPServer.extractRequestId(from: body), "req-42")
    }

    func testExtractRequestIdFromIntId() {
        let body = Data(#"{"jsonrpc":"2.0","id":7,"method":"tools/list"}"#.utf8)
        XCTAssertEqual(MCPHTTPServer.extractRequestId(from: body), "7")
    }

    func testExtractRequestIdReturnsNilWhenAbsent() {
        let body = Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8)
        XCTAssertNil(MCPHTTPServer.extractRequestId(from: body))
    }
}
