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
let session = URLSession(configuration: .ephemeral)

enum BridgeError: Error, CustomStringConvertible {
    case invalidResponse

    var description: String {
        switch self {
        case .invalidResponse: "Invalid HTTP response from NewsComb app"
        }
    }
}

func verifyAppRunning() async throws {
    // Send a minimal invalid request to check if the server is listening.
    // We expect an HTTP response (even an error) — a connection refused means the app isn't running.
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.httpBody = Data("{}".utf8)
    request.timeoutInterval = 3

    _ = try await session.data(for: request)
}

func postToApp(body: Data) async throws -> Data? {
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.httpBody = body
    request.timeoutInterval = 60

    let (data, response) = try await session.data(for: request)

    guard let httpResponse = response as? HTTPURLResponse else {
        throw BridgeError.invalidResponse
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

// MARK: - Main

// Verify the app is reachable before entering the main loop
do {
    try await verifyAppRunning()
} catch {
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
        FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
}
