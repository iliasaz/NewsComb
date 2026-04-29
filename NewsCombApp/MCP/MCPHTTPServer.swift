import Foundation
import MCP
import Network
import OSLog
import Synchronization

/// Minimal HTTP/1.1 server using Network framework for serving MCP over localhost.
///
/// Listens on a configurable TCP port (default 63548) and forwards HTTP requests
/// to `StatelessHTTPServerTransport` instances. Supports multiple concurrent client
/// sessions — each `initialize` request creates a new session with a unique ID,
/// returned via the `X-Session-Id` response header. Subsequent requests include
/// this header to route to the correct session.
final class MCPHTTPServer: Sendable {

    static let defaultPort: UInt16 = 63548
    static let sessionHeader = "X-Session-Id"

    /// Factory that creates and configures a new MCP `Server` for each client session.
    typealias ServerFactory = @Sendable (StatelessHTTPServerTransport) async -> Server

    private let listener: NWListener
    private let serverFactory: ServerFactory
    private let logger = Logger(subsystem: "com.newscomb.app", category: "MCPHTTPServer")

    /// Active sessions keyed by session ID. Old sessions are cleaned up periodically.
    private let sessions = Mutex<[String: Session]>([:])

    /// Most recently created session ID — used as default when no header is provided.
    private let latestSessionId = Mutex<String?>(nil)

    private struct Session {
        let id: String
        let transport: StatelessHTTPServerTransport
        let server: Server
        let createdAt: Date
    }

    init(serverFactory: @escaping ServerFactory, port: UInt16 = MCPHTTPServer.defaultPort) throws {
        self.serverFactory = serverFactory

        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: .ipv4(.loopback),
            port: NWEndpoint.Port(rawValue: port)!
        )
        self.listener = try NWListener(using: params)
    }

    func start() {
        listener.stateUpdateHandler = { [logger] state in
            switch state {
            case .ready:
                if let port = self.listener.port {
                    logger.info("MCP HTTP server listening on http://127.0.0.1:\(port.rawValue, privacy: .public)")
                }
            case .failed(let error):
                logger.error("MCP HTTP server failed: \(error.localizedDescription, privacy: .public)")
            case .cancelled:
                logger.info("MCP HTTP server stopped")
            default:
                break
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }

        listener.start(queue: DispatchQueue(label: "com.newscomb.mcp.http"))
    }

    func stop() {
        listener.cancel()
    }

    // MARK: - Connection Handling

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: DispatchQueue(label: "com.newscomb.mcp.http.conn"))
        readHTTPRequest(from: connection, accumulated: Data())
    }

    private func readHTTPRequest(from connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let error {
                self.logger.debug("Connection read error: \(error.localizedDescription, privacy: .public)")
                connection.cancel()
                return
            }

            var buffer = accumulated
            if let data { buffer.append(data) }

            // Try to parse a complete HTTP request from the buffer
            if let (request, _) = self.parseHTTPRequest(from: buffer) {
                self.dispatchRequest(request, on: connection)
            } else if isComplete {
                // Connection closed before we got a complete request
                connection.cancel()
            } else {
                // Need more data
                self.readHTTPRequest(from: connection, accumulated: buffer)
            }
        }
    }

    private func dispatchRequest(_ request: MCP.HTTPRequest, on connection: NWConnection) {
        Task {
            // Workspace-header check — reject mismatched bridges with a JSON-RPC error.
            if let failure = await self.validateWorkspaceHeader(request) {
                logger.warning("Workspace header validation failed: \(failure.message, privacy: .public)")
                let httpData = Self.makeJSONRPCErrorHTTPResponse(
                    requestId: Self.extractRequestId(from: request.body),
                    code: failure.code,
                    message: failure.message
                )
                connection.send(content: httpData, completion: .contentProcessed { _ in
                    connection.cancel()
                })
                return
            }

            let (transport, sessionId) = await self.resolveTransport(for: request)
            let response = await transport.handleRequest(request)
            let httpData = self.formatHTTPResponse(response, sessionId: sessionId)
            connection.send(content: httpData, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    private func validateWorkspaceHeader(_ request: MCP.HTTPRequest) async -> MCPWorkspaceValidator.ValidationFailure? {
        let active = await MainActor.run { WorkspaceCoordinator.shared.active?.directory }
        return MCPWorkspaceValidator.validate(
            requestedHeader: request.header(MCPWorkspaceValidator.headerName),
            active: active
        )
    }

    /// Constructs an HTTP/1.1 400 response with a JSON-RPC error body.
    static func makeJSONRPCErrorHTTPResponse(requestId: String?, code: Int, message: String) -> Data {
        let escapedMessage = message.replacing("\\", with: "\\\\").replacing("\"", with: "\\\"")
        let idJSON = requestId.map { "\"\($0)\"" } ?? "null"
        let body = Data("""
            {"jsonrpc":"2.0","id":\(idJSON),"error":{"code":\(code),"message":"\(escapedMessage)"}}
            """.utf8)

        var result = "HTTP/1.1 400 Bad Request\r\n"
        result += "Content-Type: application/json\r\n"
        result += "Content-Length: \(body.count)\r\n"
        result += "Connection: close\r\n"
        result += "\r\n"

        var data = Data(result.utf8)
        data.append(body)
        return data
    }

    /// Extracts the JSON-RPC `id` from a request body (string or integer).
    static func extractRequestId(from body: Data?) -> String? {
        guard let body,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return nil
        }
        if let id = json["id"] as? String { return id }
        if let id = json["id"] as? Int { return String(id) }
        return nil
    }

    // MARK: - Session Management

    /// Returns the transport for this request, creating a new session if this is an `initialize` request.
    private func resolveTransport(for request: MCP.HTTPRequest) async -> (StatelessHTTPServerTransport, String) {
        let isInitialize = request.body.flatMap { Self.isInitializeRequest($0) } ?? false

        if isInitialize {
            let sessionId = UUID().uuidString
            logger.info("New MCP client session: \(sessionId, privacy: .public)")

            // Create fresh transport + server
            let transport = StatelessHTTPServerTransport(
                validationPipeline: StandardValidationPipeline(validators: []),
                logger: nil
            )
            let server = await serverFactory(transport)

            do {
                try await server.start(transport: transport)
            } catch {
                logger.error("Failed to start MCP server for session \(sessionId, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }

            let newSession = Session(id: sessionId, transport: transport, server: server, createdAt: Date())
            sessions.withLock { $0[sessionId] = newSession }
            latestSessionId.withLock { $0 = sessionId }

            // Clean up stale sessions (older than 1 hour)
            cleanupStaleSessions()

            return (transport, sessionId)
        }

        // Try to find the session by header
        let requestSessionId = request.header(Self.sessionHeader)

        if let requestSessionId, let existing = sessions.withLock({ $0[requestSessionId] }) {
            return (existing.transport, existing.id)
        }

        // Fallback: use the most recent session
        if let latest = latestSessionId.withLock({ $0 }),
           let existing = sessions.withLock({ $0[latest] }) {
            return (existing.transport, existing.id)
        }

        // No session at all — create a temporary transport that will return an error
        logger.warning("Request received before initialize — returning temporary transport")
        let transport = StatelessHTTPServerTransport(
            validationPipeline: StandardValidationPipeline(validators: []),
            logger: nil
        )
        return (transport, "none")
    }

    /// Removes sessions older than 1 hour.
    private func cleanupStaleSessions() {
        let cutoff = Date().addingTimeInterval(-3600)
        let stale = sessions.withLock { dict -> [Session] in
            let expired = dict.values.filter { $0.createdAt < cutoff }
            for session in expired {
                dict.removeValue(forKey: session.id)
            }
            return expired
        }
        for session in stale {
            logger.info("Cleaned up stale session: \(session.id, privacy: .public)")
            Task { await session.transport.disconnect() }
        }
    }

    /// Checks if a JSON-RPC body contains an `initialize` method.
    private static func isInitializeRequest(_ body: Data) -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return false
        }
        return (json["method"] as? String) == "initialize"
    }

    // MARK: - HTTP Parsing

    /// Parses a complete HTTP request from raw bytes.
    /// Returns nil if the buffer doesn't contain a complete request yet.
    private func parseHTTPRequest(from data: Data) -> (MCP.HTTPRequest, Int)? {
        guard let headerEnd = data.findHeaderEnd() else { return nil }

        guard let headerString = String(data: data[..<headerEnd], encoding: .utf8) else {
            return nil
        }

        let lines = headerString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }

        let parts = requestLine.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2 else { return nil }

        let method = String(parts[0])
        let path = String(parts[1])

        // Parse headers
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colonIndex = line.firstIndex(of: ":") else { continue }
            let name = line[..<colonIndex].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colonIndex)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        // Read body based on Content-Length
        let bodyStart = headerEnd + 4 // skip \r\n\r\n
        let contentLength = headers["Content-Length"].flatMap(Int.init) ?? 0

        guard data.count >= bodyStart + contentLength else {
            return nil // Need more data for body
        }

        let body: Data? = contentLength > 0
            ? data[bodyStart..<(bodyStart + contentLength)]
            : nil

        let request = MCP.HTTPRequest(
            method: method,
            headers: headers,
            body: body,
            path: path
        )
        return (request, bodyStart + contentLength)
    }

    // MARK: - HTTP Response Formatting

    private func formatHTTPResponse(_ response: MCP.HTTPResponse, sessionId: String) -> Data {
        let statusCode = response.statusCode
        let statusText = Self.statusText(for: statusCode)
        let body = response.bodyData
        var headers = response.headers

        if let body {
            headers["Content-Length"] = "\(body.count)"
        } else {
            headers["Content-Length"] = "0"
        }
        headers["Connection"] = "close"
        headers[Self.sessionHeader] = sessionId

        var result = "HTTP/1.1 \(statusCode) \(statusText)\r\n"
        for (name, value) in headers {
            result += "\(name): \(value)\r\n"
        }
        result += "\r\n"

        var data = Data(result.utf8)
        if let body { data.append(body) }
        return data
    }

    private static func statusText(for code: Int) -> String {
        switch code {
        case 200: "OK"
        case 202: "Accepted"
        case 400: "Bad Request"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 406: "Not Acceptable"
        case 415: "Unsupported Media Type"
        case 500: "Internal Server Error"
        default: "Error"
        }
    }
}

// MARK: - Data Extension

private extension Data {
    /// Finds the position of the `\r\n\r\n` header terminator.
    func findHeaderEnd() -> Int? {
        let separator: [UInt8] = [0x0D, 0x0A, 0x0D, 0x0A] // \r\n\r\n
        guard count >= 4 else { return nil }
        for i in 0...(count - 4) {
            if self[i] == separator[0]
                && self[i + 1] == separator[1]
                && self[i + 2] == separator[2]
                && self[i + 3] == separator[3]
            {
                return i
            }
        }
        return nil
    }
}
