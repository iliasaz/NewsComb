import Foundation
import MCP
import Network
import OSLog
import Synchronization

/// Minimal HTTP/1.1 server using Network framework for serving MCP over localhost.
///
/// Listens on a configurable TCP port (default 63548) and forwards HTTP requests
/// to a `StatelessHTTPServerTransport`. Creates a fresh transport and MCP server
/// for each new client session (detected by `initialize` requests), following the
/// same pattern as the MCP SDK's reference `HTTPApp`.
final class MCPHTTPServer: Sendable {

    static let defaultPort: UInt16 = 63548

    /// Factory that creates and configures a new MCP `Server` for each client session.
    typealias ServerFactory = @Sendable (StatelessHTTPServerTransport) async -> Server

    private let listener: NWListener
    private let serverFactory: ServerFactory
    private let logger = Logger(subsystem: "com.newscomb.app", category: "MCPHTTPServer")

    /// The current active session — replaced on each new `initialize` request.
    private let session = Mutex<Session?>(nil)

    private struct Session {
        let transport: StatelessHTTPServerTransport
        let server: Server
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
            let transport = await self.resolveTransport(for: request)
            let response = await transport.handleRequest(request)
            let httpData = self.formatHTTPResponse(response)
            connection.send(content: httpData, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    /// Returns the transport for this request, creating a new session if this is an `initialize` request.
    private func resolveTransport(for request: MCP.HTTPRequest) async -> StatelessHTTPServerTransport {
        let isInitialize = request.body.flatMap { Self.isInitializeRequest($0) } ?? false

        if isInitialize {
            logger.info("New MCP client connecting — creating session")

            // Tear down existing session
            let oldSession = session.withLock { current -> Session? in
                let old = current
                current = nil
                return old
            }

            if let oldSession {
                await oldSession.transport.disconnect()
            }

            // Create fresh transport + server
            let transport = StatelessHTTPServerTransport(
                validationPipeline: StandardValidationPipeline(validators: []),
                logger: nil
            )
            let server = await serverFactory(transport)

            do {
                try await server.start(transport: transport)
            } catch {
                logger.error("Failed to start MCP server for new session: \(error.localizedDescription, privacy: .public)")
            }

            let newSession = Session(transport: transport, server: server)
            session.withLock { $0 = newSession }

            return transport
        }

        // Return existing session's transport
        if let current = session.withLock({ $0 }) {
            return current.transport
        }

        // No session yet and not an initialize — create one anyway so we can return an error
        logger.warning("Request received before initialize — returning temporary transport")
        return StatelessHTTPServerTransport(
            validationPipeline: StandardValidationPipeline(validators: []),
            logger: nil
        )
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

    private func formatHTTPResponse(_ response: MCP.HTTPResponse) -> Data {
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
