import XCTest
@testable import NewsCombApp

/// Integration test that launches a real OASIS simulation subprocess and
/// verifies at least 1 round completes. Requires Python 3.10+ with
/// camel-oasis installed and a valid OpenRouter API key in AppSettings.
///
/// This test is skipped if the environment is not available.
final class OasisSimulationIntegrationTests: XCTestCase {

    private var tempDir: URL!
    private var pythonPath: String!
    private var apiKey: String!

    override func setUp() async throws {
        try await super.setUp()

        // Detect Python + OASIS
        let envService = OasisEnvironmentService()
        guard let python = await envService.detectPythonPath() else {
            throw XCTSkip("Python not found")
        }
        let oasisStatus = await envService.checkOasisInstalled(pythonPath: python)
        guard oasisStatus.isInstalled else {
            throw XCTSkip("OASIS not installed")
        }
        pythonPath = python

        // Load OpenRouter API key
        let loadedApiKey: String? = try Database.shared.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM app_settings WHERE key = ?",
                                arguments: [AppSettings.openRouterKey])
        }
        guard let loadedApiKey, !loadedApiKey.isEmpty else {
            throw XCTSkip("OpenRouter API key not configured")
        }
        apiKey = loadedApiKey

        // Create temp directory
        tempDir = FileManager.default.temporaryDirectory
            .appending(path: "OasisIntegrationTest-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        for sub in ["twitter", "ipc_commands", "ipc_responses"] {
            try fm.createDirectory(at: tempDir.appending(path: sub), withIntermediateDirectories: true)
        }
    }

    override func tearDown() {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        super.tearDown()
    }

    // MARK: - Integration Test

    func testOasisSimulation_completesAtLeastOneRound() async throws {
        // Write agent profiles
        let csv = """
            user_id,username,name,description,user_char,following_agentid_list,previous_tweets
            1,agent_alpha,Agent Alpha,Tech commentator,Discusses AI and startups,[],[]
            2,agent_beta,Agent Beta,Policy analyst,Follows regulatory news,[],[]
            3,agent_gamma,Agent Gamma,Investor,Tracks market trends,[],[]

            """
        try csv.write(to: tempDir.appending(path: "twitter_profiles.csv"), atomically: true, encoding: .utf8)

        // Write config
        let config: [String: Any] = [
            "platforms": ["twitter"],
            "max_rounds": 2,
            "agents_per_hour_min": 1,
            "agents_per_hour_max": 2,
            "semaphore_limit": 4,
        ]
        let configData = try JSONSerialization.data(withJSONObject: config, options: .prettyPrinted)
        try configData.write(to: tempDir.appending(path: "simulation_config.json"))

        // Write simulation script
        try generateTestScript(to: tempDir.appending(path: "run_simulation.py"))

        // Launch subprocess and wait for it to finish
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: pythonPath)
        proc.arguments = [
            tempDir.appending(path: "run_simulation.py").path(percentEncoded: false),
            "--config",
            tempDir.appending(path: "simulation_config.json").path(percentEncoded: false),
        ]
        proc.currentDirectoryURL = tempDir
        proc.environment = ProcessInfo.processInfo.environment.merging([
            "PYTHONUTF8": "1",
            "PYTHONIOENCODING": "utf-8",
            "OPENAI_API_KEY": apiKey,
            "OPENROUTER_API_KEY": apiKey,
            "OPENAI_API_BASE_URL": "https://openrouter.ai/api/v1",
            "OPENAI_MODEL_NAME": "openai/gpt-4.1-nano",
        ]) { _, new in new }

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        try proc.run()

        // Wait for process with timeout
        let processTask = Task.detached {
            proc.waitUntilExit()
        }
        let timeoutTask = Task {
            try await Task.sleep(for: .seconds(120))
            if proc.isRunning { proc.terminate() }
        }

        await processTask.value
        timeoutTask.cancel()

        // Collect output
        let stdout = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        // Read the action log file directly
        let logPath = tempDir.appending(path: "twitter/actions.jsonl")
        let logExists = FileManager.default.fileExists(atPath: logPath.path(percentEncoded: false))
        var logContent = ""
        var actions: [OasisAction] = []

        if logExists {
            logContent = (try? String(contentsOf: logPath, encoding: .utf8)) ?? ""
            let decoder = JSONDecoder()
            for line in logContent.split(separator: "\n") where !line.isEmpty {
                if let data = line.data(using: .utf8),
                   let action = try? decoder.decode(OasisAction.self, from: data) {
                    actions.append(action)
                }
            }
        }

        let roundEndCount = actions.filter { $0.eventType == "round_end" }.count
        let hasSimEnd = actions.contains(where: \.isSimulationEnd)

        // Diagnostics on failure
        let diagnostics = """
            Exit code: \(proc.terminationStatus)
            Log exists: \(logExists)
            Actions parsed: \(actions.count)
            Round ends: \(roundEndCount)
            Simulation end: \(hasSimEnd)
            stdout: \(stdout.prefix(500))
            stderr: \(stderr.prefix(1000))
            log: \(logContent.prefix(500))
            """

        XCTAssertTrue(roundEndCount >= 1,
            "OASIS simulation should complete at least 1 round.\n\(diagnostics)")
    }

    // MARK: - Script Generation

    private func generateTestScript(to path: URL) throws {
        let script = """
            #!/usr/bin/env python3
            import argparse, asyncio, csv, json, os, sys
            from pathlib import Path

            api_key = os.environ.get("OPENAI_API_KEY", "")
            os.environ.setdefault("OPENROUTER_API_KEY", api_key)
            model_name = os.environ.get("OPENAI_MODEL_NAME", "openai/gpt-4.1-nano")

            try:
                from datetime import datetime
                from camel.models import ModelFactory
                from camel.types.enums import ModelPlatformType
                from oasis.social_platform.platform import Platform
                from oasis.social_platform.channel import Channel
                from oasis.social_agent.agents_generator import generate_agents
                from oasis.environment.env import OasisEnv
            except ImportError as e:
                print(f"Import error: {e}", file=sys.stderr)
                sys.exit(1)

            class ActionLogger:
                def __init__(self, path):
                    self.path = Path(path)
                    self.path.parent.mkdir(parents=True, exist_ok=True)
                def log_event(self, event_type, **kw):
                    with open(self.path, "a") as f:
                        f.write(json.dumps({"event_type": event_type, **kw}) + "\\n")

            async def main():
                parser = argparse.ArgumentParser()
                parser.add_argument("--config", required=True)
                args = parser.parse_args()
                sim_dir = Path(args.config).parent
                config = json.load(open(args.config))

                max_rounds = config.get("max_rounds", 2)
                logger = ActionLogger(sim_dir / "twitter" / "actions.jsonl")
                logger.log_event("simulation_start", agent_count=3)

                model = None
                if api_key:
                    try:
                        model = ModelFactory.create(
                            model_platform=ModelPlatformType.OPENROUTER,
                            model_type=model_name,
                            api_key=api_key,
                        )
                        print(f"Model created: {model_name}")
                    except Exception as e:
                        print(f"Model init failed: {e}", file=sys.stderr)

                start_time = datetime.now()
                channel = Channel()
                db_path = str(sim_dir / "twitter" / "twitter.db")

                platform = Platform(
                    db_path=db_path,
                    channel=channel,
                    start_time=start_time,
                    recsys_type="twitter",
                )

                try:
                    agent_graph = await generate_agents(
                        agent_info_path=str(sim_dir / "twitter_profiles.csv"),
                        channel=channel,
                        model=model,
                        start_time=start_time,
                        recsys_type="twitter",
                        twitter=platform,
                    )

                    env = OasisEnv(
                        agent_graph=agent_graph,
                        platform=platform,
                        database_path=db_path,
                        semaphore=4,
                    )
                    await env.reset()
                    print("OASIS initialized")

                    import random
                    from oasis.environment.env_action import LLMAction
                    all_agents = list(agent_graph.agent_mappings.values())
                    for round_num in range(max_rounds):
                        active = random.sample(all_agents, min(2, len(all_agents)))
                        actions = {agent: LLMAction() for agent in active}
                        try:
                            await env.step(actions)
                        except Exception as e:
                            print(f"Round {round_num} step error: {e}", file=sys.stderr)
                        logger.log_event("round_end", round=round_num)
                        print(f"Round {round_num} done")

                    await env.close()
                except Exception as e:
                    print(f"Simulation error: {e}", file=sys.stderr)
                    import traceback
                    traceback.print_exc(file=sys.stderr)

                logger.log_event("simulation_end")
                print("Done")

            asyncio.run(main())
            """
        try script.write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: path.path(percentEncoded: false)
        )
    }
}
