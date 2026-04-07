import Foundation

/// NewsComb MCP Bridge — translates stdio ↔ HTTP for the in-app MCP server.
///
/// Claude Code launches this binary over stdio. Each JSON-RPC message read from
/// stdin is POSTed to the NewsComb app's HTTP endpoint. The HTTP response body
/// is written back to stdout.
///
/// Architecture:
///   Claude Code ←stdio→ this bridge ←HTTP→ NewsCombApp (localhost:63548)
///
/// Requires the NewsComb app to be running (it starts the HTTP server on launch).

// MARK: - HTTP Client

let endpoint = URL(string: "http://127.0.0.1:63548/mcp")!
let sessionHeader = "X-Session-Id"
let urlSession = URLSession(configuration: .ephemeral)

/// The session ID assigned by the server on `initialize`. Included in all subsequent requests.
/// Safe to use without isolation — the bridge processes requests sequentially.
nonisolated(unsafe) var currentSessionId: String?

enum BridgeError: Error, CustomStringConvertible {
    case invalidResponse
    case appNotRunning

    var description: String {
        switch self {
        case .invalidResponse: "Invalid HTTP response from NewsComb app"
        case .appNotRunning: "NewsComb app is not running"
        }
    }
}

/// Waits for the app to become reachable, retrying up to `maxAttempts` times.
func waitForApp(maxAttempts: Int = 5, delay: Duration = .milliseconds(500)) async -> Bool {
    for attempt in 1...maxAttempts {
        do {
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.httpBody = Data("{}".utf8)
            request.timeoutInterval = 2

            _ = try await urlSession.data(for: request)
            return true
        } catch {
            if attempt < maxAttempts {
                try? await Task.sleep(for: delay)
            }
        }
    }
    return false
}

func postToApp(body: Data) async throws -> Data? {
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.httpBody = body
    request.timeoutInterval = 120

    // Include session ID if we have one
    if let sessionId = currentSessionId {
        request.setValue(sessionId, forHTTPHeaderField: sessionHeader)
    }

    let (data, response) = try await urlSession.data(for: request)

    guard let httpResponse = response as? HTTPURLResponse else {
        throw BridgeError.invalidResponse
    }

    // Capture session ID from response
    if let serverSessionId = httpResponse.value(forHTTPHeaderField: sessionHeader) {
        currentSessionId = serverSessionId
    }

    switch httpResponse.statusCode {
    case 200:
        return data
    case 202:
        // Accepted (notification) — no response body to forward
        return nil
    default:
        // Forward error responses to stdout so the MCP client sees the JSON-RPC error
        return data.isEmpty ? nil : data
    }
}

/// Constructs a JSON-RPC error response for transport-level failures.
func makeTransportError(id: String?, message: String) -> Data {
    let idValue = id.map { "\"\($0)\"" } ?? "null"
    let json = """
        {"jsonrpc":"2.0","id":\(idValue),"error":{"code":-32000,"message":"\(message)"}}
        """
    return Data(json.utf8)
}

/// Extracts the "id" field from a JSON-RPC message.
func extractRequestId(from data: Data) -> String? {
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return nil
    }
    if let id = json["id"] as? String { return id }
    if let id = json["id"] as? Int { return String(id) }
    return nil
}

// MARK: - Main

// Wait for the app to become reachable (retries for up to ~2.5 seconds)
let appReady = await waitForApp()
if !appReady {
    FileHandle.standardError.write(Data("error: NewsComb app is not running. Launch NewsCombApp first.\n".utf8))
    exit(1)
}

// Main loop: read stdin line by line, POST to app, write response to stdout
while let line = readLine(strippingNewline: true) {
    guard !line.isEmpty else { continue }
    guard let body = line.data(using: .utf8) else { continue }

    do {
        let responseData = try await postToApp(body: body)
        if let responseData, !responseData.isEmpty {
            FileHandle.standardOutput.write(responseData)
            FileHandle.standardOutput.write(Data("\n".utf8))
        }
    } catch {
        // Don't exit on transient errors — return a JSON-RPC error instead
        // so the MCP client can decide what to do.
        let requestId = extractRequestId(from: body)
        let errorResponse = makeTransportError(
            id: requestId,
            message: "Bridge transport error: \(error.localizedDescription)"
        )
        FileHandle.standardOutput.write(errorResponse)
        FileHandle.standardOutput.write(Data("\n".utf8))

        // If it's a connection refused (app crashed/quit), exit so Claude Code
        // can restart the bridge when the app is back.
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCannotConnectToHost {
            FileHandle.standardError.write(Data("error: Lost connection to NewsComb app.\n".utf8))
            exit(1)
        }
    }
}
