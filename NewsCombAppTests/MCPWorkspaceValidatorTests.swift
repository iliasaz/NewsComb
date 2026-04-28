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
