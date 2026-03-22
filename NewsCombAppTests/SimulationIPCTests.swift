import XCTest
@testable import NewsCombApp

/// Tests for the simulation IPC pipeline: command/response filesystem exchange,
/// JSONL action log monitoring, and action ingestion into the social graph.
///
/// These tests use real filesystem I/O with temp directories — no mocks for the IPC
/// layer itself. The "OASIS side" is simulated by writing response files and JSONL
/// entries directly, exactly as the real Python subprocess would.
final class SimulationIPCTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appending(path: "SimulationIPCTests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try! FileManager.default.createDirectory(at: tempDir.appending(path: "ipc_commands"), withIntermediateDirectories: true)
        try! FileManager.default.createDirectory(at: tempDir.appending(path: "ipc_responses"), withIntermediateDirectories: true)
        try! FileManager.default.createDirectory(at: tempDir.appending(path: "twitter"), withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - IPC Command Encoding

    func testIPCCommand_interviewEncoding() throws {
        let command = IPCCommand.interview(agentId: 42, prompt: "What do you think?")
        let data = try JSONEncoder().encode(command)
        let decoded = try JSONDecoder().decode(IPCCommand.self, from: data)

        XCTAssertEqual(decoded.commandType, .interview)
        XCTAssertEqual(decoded.payload["agent_id"], "42")
        XCTAssertEqual(decoded.payload["prompt"], "What do you think?")
    }

    func testIPCCommand_closeEnvEncoding() throws {
        let command = IPCCommand.closeEnvironment()
        let data = try JSONEncoder().encode(command)
        let decoded = try JSONDecoder().decode(IPCCommand.self, from: data)

        XCTAssertEqual(decoded.commandType, .closeEnv)
        XCTAssertTrue(decoded.payload.isEmpty)
    }

    func testIPCResponse_decoding() throws {
        let json = """
        {"success": true, "result": "Agent 42 says hello"}
        """
        let data = json.data(using: .utf8)!
        let response = try JSONDecoder().decode(IPCResponse.self, from: data)

        XCTAssertTrue(response.success)
        XCTAssertEqual(response.result, "Agent 42 says hello")
        XCTAssertNil(response.error)
    }

    func testIPCResponse_errorDecoding() throws {
        let json = """
        {"success": false, "error": "Agent not found"}
        """
        let data = json.data(using: .utf8)!
        let response = try JSONDecoder().decode(IPCResponse.self, from: data)

        XCTAssertFalse(response.success)
        XCTAssertNil(response.result)
        XCTAssertEqual(response.error, "Agent not found")
    }

    // MARK: - IPC Client: Command-Response Exchange

    func testIPCClient_sendCommand_receivesResponse() async throws {
        let client = SimulationIPCClient(simulationDir: tempDir)

        // Simulate OASIS: watch for command files and write response
        let commandsDir = tempDir.appending(path: "ipc_commands")
        let responsesDir = tempDir.appending(path: "ipc_responses")

        // Start a background task that simulates the OASIS subprocess
        let oasisTask = Task {
            // Poll for command files
            while !Task.isCancelled {
                let files = (try? FileManager.default.contentsOfDirectory(atPath: commandsDir.path(percentEncoded: false))) ?? []
                for file in files where file.hasSuffix(".json") {
                    let commandId = file.replacing(".json", with: "")
                    // Write a response
                    let response = IPCResponse(success: true, result: "mock response", error: nil)
                    let data = try! JSONEncoder().encode(response)
                    try! data.write(to: responsesDir.appending(path: "\(commandId).json"))
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }

        let command = IPCCommand.interview(agentId: 1, prompt: "Hello")
        let response = try await client.sendCommand(command, timeout: .seconds(5))

        oasisTask.cancel()

        XCTAssertTrue(response.success)
        XCTAssertEqual(response.result, "mock response")
    }

    func testIPCClient_sendCommand_writesCommandFile() async throws {
        let client = SimulationIPCClient(simulationDir: tempDir)
        let commandsDir = tempDir.appending(path: "ipc_commands")
        let responsesDir = tempDir.appending(path: "ipc_responses")

        // Write a response immediately for any command (before the client polls)
        let oasisTask = Task {
            while !Task.isCancelled {
                let files = (try? FileManager.default.contentsOfDirectory(atPath: commandsDir.path(percentEncoded: false))) ?? []
                for file in files where file.hasSuffix(".json") {
                    // Read the command to verify its contents
                    let commandPath = commandsDir.appending(path: file)
                    let commandData = try! Data(contentsOf: commandPath)
                    let command = try! JSONDecoder().decode(IPCCommand.self, from: commandData)

                    // Verify it's a properly formed command
                    XCTAssertEqual(command.commandType, .closeEnv)

                    let commandId = file.replacing(".json", with: "")
                    let response = IPCResponse(success: true, result: "closed", error: nil)
                    let data = try! JSONEncoder().encode(response)
                    try! data.write(to: responsesDir.appending(path: "\(commandId).json"))
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }

        let response = try await client.sendCommand(IPCCommand.closeEnvironment(), timeout: .seconds(5))
        oasisTask.cancel()

        XCTAssertTrue(response.success)
    }

    func testIPCClient_timeout() async {
        let client = SimulationIPCClient(simulationDir: tempDir)

        // No OASIS subprocess to write responses — should timeout
        do {
            _ = try await client.sendCommand(
                IPCCommand.interview(agentId: 1, prompt: "Hello"),
                timeout: .seconds(1)
            )
            XCTFail("Should have thrown timeout error")
        } catch {
            XCTAssertTrue(error is SimulationIPCError)
            if case SimulationIPCError.timeout = error {
                // Expected
            } else {
                XCTFail("Expected timeout error, got: \(error)")
            }
        }
    }

    func testIPCClient_interview_success() async throws {
        let client = SimulationIPCClient(simulationDir: tempDir)
        let commandsDir = tempDir.appending(path: "ipc_commands")
        let responsesDir = tempDir.appending(path: "ipc_responses")

        let oasisTask = Task {
            while !Task.isCancelled {
                let files = (try? FileManager.default.contentsOfDirectory(atPath: commandsDir.path(percentEncoded: false))) ?? []
                for file in files where file.hasSuffix(".json") {
                    let commandId = file.replacing(".json", with: "")
                    let response = IPCResponse(success: true, result: "I think AI is transformative.", error: nil)
                    let data = try! JSONEncoder().encode(response)
                    try! data.write(to: responsesDir.appending(path: "\(commandId).json"))
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }

        let answer = try await client.interview(agentId: 5, prompt: "What do you think about AI?")
        oasisTask.cancel()

        XCTAssertEqual(answer, "I think AI is transformative.")
    }

    func testIPCClient_interview_failure() async {
        let client = SimulationIPCClient(simulationDir: tempDir)
        let commandsDir = tempDir.appending(path: "ipc_commands")
        let responsesDir = tempDir.appending(path: "ipc_responses")

        let oasisTask = Task {
            while !Task.isCancelled {
                let files = (try? FileManager.default.contentsOfDirectory(atPath: commandsDir.path(percentEncoded: false))) ?? []
                for file in files where file.hasSuffix(".json") {
                    let commandId = file.replacing(".json", with: "")
                    let response = IPCResponse(success: false, result: nil, error: "Agent 99 not found")
                    let data = try! JSONEncoder().encode(response)
                    try! data.write(to: responsesDir.appending(path: "\(commandId).json"))
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }

        do {
            _ = try await client.interview(agentId: 99, prompt: "Hello")
            XCTFail("Should have thrown")
        } catch {
            XCTAssertTrue(error is SimulationIPCError)
        }

        oasisTask.cancel()
    }

    func testIPCClient_cleansUpFiles() async throws {
        let client = SimulationIPCClient(simulationDir: tempDir)
        let commandsDir = tempDir.appending(path: "ipc_commands")
        let responsesDir = tempDir.appending(path: "ipc_responses")

        let oasisTask = Task {
            while !Task.isCancelled {
                let files = (try? FileManager.default.contentsOfDirectory(atPath: commandsDir.path(percentEncoded: false))) ?? []
                for file in files where file.hasSuffix(".json") {
                    let commandId = file.replacing(".json", with: "")
                    let response = IPCResponse(success: true, result: "ok", error: nil)
                    let data = try! JSONEncoder().encode(response)
                    try! data.write(to: responsesDir.appending(path: "\(commandId).json"))
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }

        _ = try await client.sendCommand(IPCCommand.closeEnvironment(), timeout: .seconds(5))
        oasisTask.cancel()

        // Give filesystem a moment
        try await Task.sleep(for: .milliseconds(100))

        // Command file should be cleaned up
        let remainingCommands = (try? FileManager.default.contentsOfDirectory(atPath: commandsDir.path(percentEncoded: false))) ?? []
        let jsonCommands = remainingCommands.filter { $0.hasSuffix(".json") }
        XCTAssertTrue(jsonCommands.isEmpty, "Command files should be cleaned up, found: \(jsonCommands)")
    }

    // MARK: - Action Log Monitor

    func testActionLogMonitor_readsNewActions() async throws {
        let logFile = tempDir.appending(path: "twitter/actions.jsonl")

        // Write some initial actions
        let actions = [
            """
            {"event_type":"simulation_start","agent_count":5}
            """,
            """
            {"agent_id":1,"action_type":"create_post","content":"Hello world","round":0}
            """,
            """
            {"agent_id":2,"action_type":"like_post","target_post_id":1,"round":0}
            """,
            """
            {"event_type":"round_end","round":0}
            """,
        ]
        try actions.joined(separator: "\n").appending("\n").write(to: logFile, atomically: true, encoding: .utf8)

        let monitor = ActionLogMonitor(logFiles: [logFile])
        let stream = await monitor.startMonitoring()

        var allActions: [OasisAction] = []
        for await batch in stream {
            allActions.append(contentsOf: batch)
            // We got actions — stop monitoring
            await monitor.stopMonitoring()
            break
        }

        XCTAssertFalse(allActions.isEmpty, "Should have read actions from JSONL")

        // Check we got the event and the agent actions
        let events = allActions.filter(\.isEvent)
        let agentActions = allActions.filter { !$0.isEvent }

        XCTAssertTrue(events.contains { $0.eventType == "simulation_start" })
        XCTAssertTrue(events.contains { $0.eventType == "round_end" })
        XCTAssertEqual(agentActions.count, 2)
        XCTAssertEqual(agentActions[0].actionType, "create_post")
        XCTAssertEqual(agentActions[0].content, "Hello world")
        XCTAssertEqual(agentActions[1].actionType, "like_post")
    }

    func testActionLogMonitor_detectsSimulationEnd() async throws {
        let logFile = tempDir.appending(path: "twitter/actions.jsonl")

        // Write actions including simulation_end
        let content = """
        {"event_type":"simulation_start","agent_count":3}
        {"agent_id":1,"action_type":"create_post","content":"Post 1","round":0}
        {"event_type":"round_end","round":0}
        {"event_type":"simulation_end"}

        """
        try content.write(to: logFile, atomically: true, encoding: .utf8)

        let monitor = ActionLogMonitor(logFiles: [logFile])
        let stream = await monitor.startMonitoring()

        var gotSimulationEnd = false
        for await batch in stream {
            if batch.contains(where: \.isSimulationEnd) {
                gotSimulationEnd = true
            }
            // Stream should finish automatically after simulation_end
        }

        XCTAssertTrue(gotSimulationEnd, "Should have detected simulation_end event")
    }

    func testActionLogMonitor_incrementalReads() async throws {
        let logFile = tempDir.appending(path: "twitter/actions.jsonl")

        // Start with empty file
        try "".write(to: logFile, atomically: true, encoding: .utf8)

        let monitor = ActionLogMonitor(logFiles: [logFile])
        let stream = await monitor.startMonitoring()

        // Write actions after monitoring starts (simulating a running OASIS process)
        Task {
            try await Task.sleep(for: .milliseconds(500))

            // Append round 0
            let handle = try FileHandle(forWritingTo: logFile)
            handle.seekToEndOfFile()
            let round0 = """
            {"agent_id":1,"action_type":"create_post","content":"Round 0 post","round":0}
            {"event_type":"round_end","round":0}

            """
            handle.write(round0.data(using: .utf8)!)
            try handle.close()

            try await Task.sleep(for: .seconds(3))

            // Append simulation_end
            let handle2 = try FileHandle(forWritingTo: logFile)
            handle2.seekToEndOfFile()
            handle2.write("{\"event_type\":\"simulation_end\"}\n".data(using: .utf8)!)
            try handle2.close()
        }

        var totalActions: [OasisAction] = []
        for await batch in stream {
            totalActions.append(contentsOf: batch)
            if batch.contains(where: \.isSimulationEnd) {
                break
            }
        }

        XCTAssertFalse(totalActions.isEmpty, "Should have received actions")
        let posts = totalActions.filter { $0.actionType == "create_post" }
        XCTAssertEqual(posts.count, 1)
        XCTAssertEqual(posts.first?.content, "Round 0 post")
        XCTAssertTrue(totalActions.contains(where: \.isSimulationEnd))
    }

    func testActionLogMonitor_stopMonitoring() async throws {
        let logFile = tempDir.appending(path: "twitter/actions.jsonl")
        try "".write(to: logFile, atomically: true, encoding: .utf8)

        let monitor = ActionLogMonitor(logFiles: [logFile])
        let stream = await monitor.startMonitoring()

        let isMonitoring = await monitor.monitoring
        XCTAssertTrue(isMonitoring)
        await monitor.stopMonitoring()
        let isStopped = await monitor.monitoring
        XCTAssertFalse(isStopped)

        // Stream should finish
        for await _ in stream {
            XCTFail("Stream should be empty after stopping")
        }
    }

    // MARK: - OasisAction Parsing

    func testOasisAction_agentAction() throws {
        let json = """
        {"agent_id":3,"agent_name":"TechCorp","action_type":"create_post","content":"AI is the future","round":5,"success":true}
        """
        let action = try JSONDecoder().decode(OasisAction.self, from: json.data(using: .utf8)!)

        XCTAssertEqual(action.agentId, 3)
        XCTAssertEqual(action.agentName, "TechCorp")
        XCTAssertEqual(action.actionType, "create_post")
        XCTAssertEqual(action.content, "AI is the future")
        XCTAssertEqual(action.round, 5)
        XCTAssertEqual(action.success, true)
        XCTAssertFalse(action.isEvent)
        XCTAssertFalse(action.isSimulationEnd)
    }

    func testOasisAction_eventAction() throws {
        let json = """
        {"event_type":"round_end","round":10}
        """
        let action = try JSONDecoder().decode(OasisAction.self, from: json.data(using: .utf8)!)

        XCTAssertTrue(action.isEvent)
        XCTAssertEqual(action.eventType, "round_end")
        XCTAssertEqual(action.round, 10)
        XCTAssertFalse(action.isSimulationEnd)
    }

    func testOasisAction_simulationEnd() throws {
        let json = """
        {"event_type":"simulation_end"}
        """
        let action = try JSONDecoder().decode(OasisAction.self, from: json.data(using: .utf8)!)

        XCTAssertTrue(action.isEvent)
        XCTAssertTrue(action.isSimulationEnd)
    }

    // MARK: - Action Ingestion

    func testActionIngestion_latestRound() {
        let ingestionService = ActionIngestionService()
        let actionsWithRounds: [OasisAction] = [
            makeAction(round: 0, eventType: "round_end"),
            makeAction(round: 1, eventType: "round_end"),
            makeAction(round: 2, eventType: "round_end"),
        ]

        let latest = ingestionService.latestRound(in: actionsWithRounds)
        XCTAssertEqual(latest, 2)
    }

    func testActionIngestion_latestRound_noEvents() {
        let ingestionService = ActionIngestionService()
        let actions = [
            makeAction(agentId: 1, actionType: "create_post", round: 5, content: "hello"),
        ]

        let latest = ingestionService.latestRound(in: actions)
        XCTAssertNil(latest, "No round_end events means no latest round")
    }

    func testActionIngestion_filtersEventActions() throws {
        let ingestionService = ActionIngestionService()
        let actions: [OasisAction] = [
            makeAction(eventType: "simulation_start"),
            makeAction(eventType: "round_end"),
            makeAction(eventType: "simulation_end"),
        ]

        // Events should not create any DB records
        let result = try ingestionService.ingest(
            actions: actions,
            simulationId: "test-sim",
            agentMapping: [:]
        )
        XCTAssertEqual(result.totalCreated, 0)
    }

    func testActionIngestion_unmappedAgentsSkipped() throws {
        let ingestionService = ActionIngestionService()
        let actions: [OasisAction] = [
            makeAction(agentId: 999, actionType: "create_post", round: 0, content: "hello"),
        ]

        // Agent 999 not in mapping — should be skipped
        let result = try ingestionService.ingest(
            actions: actions,
            simulationId: "test-sim",
            agentMapping: [1: 100]  // only agent 1 mapped
        )
        XCTAssertEqual(result.totalCreated, 0)
    }
}

// MARK: - OasisAction Test Helpers

private func makeAction(
    agentId: Int? = nil,
    agentName: String? = nil,
    actionType: String? = nil,
    round: Int? = nil,
    content: String? = nil,
    targetPostId: Int? = nil,
    success: Bool? = nil,
    timestamp: Double? = nil,
    eventType: String? = nil
) -> OasisAction {
    // Build JSON and decode to respect CodingKeys
    var dict: [String: Any] = [:]
    if let v = agentId { dict["agent_id"] = v }
    if let v = agentName { dict["agent_name"] = v }
    if let v = actionType { dict["action_type"] = v }
    if let v = round { dict["round"] = v }
    if let v = content { dict["content"] = v }
    if let v = targetPostId { dict["target_post_id"] = v }
    if let v = success { dict["success"] = v }
    if let v = timestamp { dict["timestamp"] = v }
    if let v = eventType { dict["event_type"] = v }

    let data = try! JSONSerialization.data(withJSONObject: dict)
    return try! JSONDecoder().decode(OasisAction.self, from: data)
}
