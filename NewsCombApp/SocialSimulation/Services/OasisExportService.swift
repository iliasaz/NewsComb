import Foundation
import GRDB
import OSLog

/// Exports social agent profiles and configuration to OASIS-compatible formats.
///
/// Creates the simulation working directory with profile files (CSV/JSON),
/// configuration, and the Python simulation script.
final class OasisExportService: Sendable {

    private let database = Database.shared
    private let logger = Logger(subsystem: "com.newscomb", category: "OasisExportService")

    // MARK: - Public API

    /// Exports agents and configuration for an OASIS simulation run.
    ///
    /// Creates the directory structure:
    /// ```
    /// ~/Library/Application Support/NewsComb/simulations/{sim_id}/
    /// ├── twitter_profiles.csv
    /// ├── reddit_profiles.json
    /// ├── simulation_config.json
    /// ├── run_simulation.py
    /// ├── ipc_commands/
    /// ├── ipc_responses/
    /// ├── twitter/
    /// └── reddit/
    /// ```
    ///
    /// - Returns: The URL of the simulation directory.
    func exportSimulation(simulationId: String, config: SimulationConfig) async throws -> URL {
        logger.info("Exporting simulation \(simulationId, privacy: .public)")

        let simDir = try createSimulationDirectory(simulationId: simulationId)

        // Load agents for this simulation
        let agents = try database.read { db in
            try SocialAgent
                .filter(SocialAgent.Columns.simulationId == simulationId)
                .order(SocialAgent.Columns.id)
                .fetchAll(db)
        }

        guard !agents.isEmpty else {
            throw OasisExportError.noAgents
        }

        // Export profiles per platform
        for platform in config.platforms {
            switch platform {
            case "twitter":
                try exportTwitterProfiles(agents: agents, to: simDir)
            case "reddit":
                try exportRedditProfiles(agents: agents, to: simDir)
            default:
                logger.warning("Unknown platform: \(platform, privacy: .public)")
            }
        }

        // Export config
        try exportConfig(config: config, agentCount: agents.count, to: simDir)

        // Generate simulation script
        try generateSimulationScript(config: config, to: simDir)

        // Update simulation record with directory path
        try database.write { db in
            try db.execute(
                sql: "UPDATE social_simulation SET sim_directory = ? WHERE id = ?",
                arguments: [simDir.path(percentEncoded: false), simulationId]
            )
        }

        logger.info("Export complete to \(simDir.path(percentEncoded: false), privacy: .public)")
        return simDir
    }

    // MARK: - Directory Setup

    private func createSimulationDirectory(simulationId: String) throws -> URL {
        let fileManager = FileManager.default
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let simDir = appSupport
            .appending(path: "NewsComb")
            .appending(path: "simulations")
            .appending(path: simulationId)

        try fileManager.createDirectory(at: simDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: simDir.appending(path: "ipc_commands"), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: simDir.appending(path: "ipc_responses"), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: simDir.appending(path: "twitter"), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: simDir.appending(path: "reddit"), withIntermediateDirectories: true)

        return simDir
    }

    // MARK: - Twitter Profile Export (CSV)

    private func exportTwitterProfiles(agents: [SocialAgent], to directory: URL) throws {
        var csv = "user_id,username,name,bio,persona\n"

        for agent in agents {
            let userId = agent.oasisUserId ?? Int(agent.id ?? 0)
            let username = sanitizeCSV(agent.displayName.lowercased().replacing(" ", with: "_"))
            let name = sanitizeCSV(agent.displayName)
            let bio = sanitizeCSV(agent.bio)
            let persona = sanitizeCSV(agent.personaJson ?? "{}")

            csv += "\(userId),\(username),\(name),\(bio),\(persona)\n"
        }

        let filePath = directory.appending(path: "twitter_profiles.csv")
        try csv.write(to: filePath, atomically: true, encoding: .utf8)
        logger.info("Exported \(agents.count) Twitter profiles")
    }

    // MARK: - Reddit Profile Export (JSON)

    private func exportRedditProfiles(agents: [SocialAgent], to directory: URL) throws {
        var profiles: [[String: Any]] = []

        for agent in agents {
            let userId = agent.oasisUserId ?? Int(agent.id ?? 0)
            let persona = agent.persona

            var profile: [String: Any] = [
                "user_id": userId,
                "username": agent.displayName.lowercased().replacing(" ", with: "_"),
                "name": agent.displayName,
                "bio": agent.bio,
                "karma": Int.random(in: 100...10000),
                "interested_topics": persona?.interests ?? []
            ]

            if let personaJson = agent.personaJson {
                profile["persona"] = personaJson
            }

            profiles.append(profile)
        }

        let data = try JSONSerialization.data(withJSONObject: profiles, options: [.prettyPrinted, .sortedKeys])
        let filePath = directory.appending(path: "reddit_profiles.json")
        try data.write(to: filePath)
        logger.info("Exported \(agents.count) Reddit profiles")
    }

    // MARK: - Config Export

    private func exportConfig(config: SimulationConfig, agentCount: Int, to directory: URL) throws {
        // Read LLM model from AppSettings for inclusion in config
        let llmModel = try? database.read { db in
            try AppSettings.filter(AppSettings.Columns.key == AppSettings.openRouterModel).fetchOne(db)?.value
        }

        let configDict: [String: Any] = [
            "max_rounds": config.maxRounds,
            "minutes_per_round": config.minutesPerRound,
            "platforms": config.platforms,
            "agents_per_hour_min": config.agentsPerHourMin,
            "agents_per_hour_max": config.agentsPerHourMax,
            "agent_count": agentCount,
            "semaphore_limit": config.semaphoreLimit,
            "llm_base_url": "https://openrouter.ai/api/v1",
            "llm_model_name": llmModel ?? "meta-llama/llama-4-maverick",
        ]

        let data = try JSONSerialization.data(withJSONObject: configDict, options: [.prettyPrinted, .sortedKeys])
        let filePath = directory.appending(path: "simulation_config.json")
        try data.write(to: filePath)
    }

    // MARK: - Script Generation

    private func generateSimulationScript(config: SimulationConfig, to directory: URL) throws {
        // swiftlint:disable:next function_body_length
        let script = """
            #!/usr/bin/env python3
            \"\"\"
            OASIS social simulation script generated by NewsComb.
            Reads LLM credentials from environment variables, loads agent profiles,
            runs the simulation, and enters IPC wait mode for interviews.
            \"\"\"
            import argparse
            import asyncio
            import csv
            import json
            import os
            import sys
            import time
            from pathlib import Path

            # ── LLM Configuration ──
            # NewsComb passes these via environment variables
            api_key = os.environ.get("OPENAI_API_KEY", "")
            base_url = os.environ.get("OPENAI_API_BASE_URL", "")
            model_name = os.environ.get("OPENAI_MODEL_NAME", "meta-llama/llama-4-maverick")

            if not api_key:
                print("WARNING: OPENAI_API_KEY not set. Agent LLM calls will fail.", file=sys.stderr)

            # Set for camel-ai (which reads OPENAI_API_KEY internally)
            if base_url:
                os.environ["OPENAI_API_BASE_URL"] = base_url

            # ── Imports (after env vars set) ──
            try:
                from datetime import datetime
                from camel.models import ModelFactory
                from camel.types.enums import ModelPlatformType
                from oasis.social_platform.platform import Platform
                from oasis.social_platform.channel import Channel
                from oasis.social_platform.typing import ActionType
                from oasis.social_agent.agents_generator import generate_agents
                from oasis.environment.env import OasisEnv
            except ImportError as e:
                print(f"ERROR: Required package not installed: {e}", file=sys.stderr)
                print("Run: pip install camel-oasis==0.2.5", file=sys.stderr)
                sys.exit(1)


            def load_config(config_path):
                with open(config_path) as f:
                    return json.load(f)


            def load_twitter_profiles(sim_dir):
                \"\"\"Load agent profiles from Twitter CSV format.\"\"\"
                profiles = []
                csv_path = sim_dir / "twitter_profiles.csv"
                if not csv_path.exists():
                    return profiles
                with open(csv_path, newline="", encoding="utf-8") as f:
                    reader = csv.DictReader(f)
                    for row in reader:
                        profiles.append({
                            "user_id": int(row.get("user_id", 0)),
                            "username": row.get("username", ""),
                            "name": row.get("name", ""),
                            "bio": row.get("bio", ""),
                            "persona": row.get("persona", ""),
                        })
                return profiles


            class ActionLogger:
                \"\"\"Logs agent actions and simulation events to JSONL files.\"\"\"

                def __init__(self, log_path):
                    self.log_path = Path(log_path)
                    self.log_path.parent.mkdir(parents=True, exist_ok=True)

                def log_action(self, **kwargs):
                    with open(self.log_path, "a", encoding="utf-8") as f:
                        f.write(json.dumps(kwargs, ensure_ascii=False) + "\\n")

                def log_event(self, event_type, **kwargs):
                    entry = {"event_type": event_type, **kwargs}
                    with open(self.log_path, "a", encoding="utf-8") as f:
                        f.write(json.dumps(entry, ensure_ascii=False) + "\\n")


            async def run_simulation(sim_dir, config):
                \"\"\"Run the OASIS simulation loop.\"\"\"
                platforms = config.get("platforms", ["twitter"])
                max_rounds = config.get("max_rounds", 72)
                semaphore_limit = config.get("semaphore_limit", 128)
                agents_per_hour_min = config.get("agents_per_hour_min", 3)
                agents_per_hour_max = config.get("agents_per_hour_max", 10)

                profiles = load_twitter_profiles(sim_dir)
                if not profiles:
                    print("ERROR: No agent profiles found.", file=sys.stderr)
                    sys.exit(1)

                print(f"Loaded {len(profiles)} agent profiles")
                print(f"Running {max_rounds} rounds on platforms: {platforms}")
                print(f"LLM model: {model_name}")
                print(f"API base: {base_url or 'default'}")

                # Set up action loggers per platform
                loggers = {}
                for platform in platforms:
                    log_path = sim_dir / platform / "actions.jsonl"
                    loggers[platform] = ActionLogger(log_path)
                    loggers[platform].log_event("simulation_start", agent_count=len(profiles))

                # Initialize LLM model for agent decisions
                # OpenRouter expects OPENROUTER_API_KEY env var
                model = None
                if api_key:
                    os.environ["OPENROUTER_API_KEY"] = api_key
                    try:
                        model = ModelFactory.create(
                            model_platform=ModelPlatformType.OPENROUTER,
                            model_type=model_name,
                            api_key=api_key,
                        )
                        print(f"LLM model initialized: {model_name}")
                    except Exception as e:
                        print(f"WARNING: Failed to create LLM model: {e}", file=sys.stderr)
                        print("Simulation will run with limited agent behavior.", file=sys.stderr)

                # Run simulation for each platform
                for platform_name in platforms:
                    logger = loggers[platform_name]
                    print(f"\\nStarting {platform_name} simulation...")

                    try:
                        db_path = str(sim_dir / platform_name / f"{platform_name}.db")
                        start_time = datetime.now()
                        channel = Channel()

                        platform = Platform(
                            db_path=db_path,
                            channel=channel,
                            start_time=start_time,
                            recsys_type=platform_name,
                        )

                        agent_graph = await generate_agents(
                            agent_info_path=str(sim_dir / "twitter_profiles.csv"),
                            channel=channel,
                            model=model,
                            start_time=start_time,
                            recsys_type=platform_name,
                        )

                        env = OasisEnv(
                            agent_graph=agent_graph,
                            platform=platform,
                            database_path=db_path,
                            semaphore=semaphore_limit,
                        )

                        await env.reset()
                        print(f"OASIS environment initialized with {len(profiles)} agents")

                        import random
                        for round_num in range(max_rounds):
                            num_active = random.randint(agents_per_hour_min, agents_per_hour_max)
                            num_active = min(num_active, len(profiles))

                            actions = []
                            active_agents = random.sample(range(len(profiles)), num_active)
                            for agent_idx in active_agents:
                                actions.append(("llm", agent_idx))

                            try:
                                await env.step(actions)
                            except Exception as e:
                                print(f"  Round {round_num} error: {e}", file=sys.stderr)

                            logger.log_event("round_end", round=round_num)

                            if round_num % 10 == 0:
                                print(f"  Completed round {round_num}/{max_rounds}")

                        await env.close()

                    except Exception as e:
                        print(f"ERROR in {platform_name} simulation: {e}", file=sys.stderr)
                        import traceback
                        traceback.print_exc()

                    logger.log_event("simulation_end")

                print("\\nSimulation complete. Entering IPC wait mode...")
                await ipc_wait_mode(sim_dir)


            async def ipc_wait_mode(sim_dir):
                \"\"\"Poll for IPC commands (interviews, close).\"\"\"
                commands_dir = sim_dir / "ipc_commands"
                responses_dir = sim_dir / "ipc_responses"

                status_file = sim_dir / "env_status.json"
                with open(status_file, "w") as f:
                    json.dump({"status": "alive"}, f)

                while True:
                    for cmd_file in sorted(commands_dir.glob("*.json")):
                        try:
                            with open(cmd_file) as f:
                                command = json.load(f)

                            cmd_type = command.get("command_type")
                            payload = command.get("payload", {})
                            command_id = cmd_file.stem

                            if cmd_type == "CLOSE_ENV":
                                response = {"success": True, "result": "Environment closed"}
                                with open(responses_dir / f"{command_id}.json", "w") as f:
                                    json.dump(response, f)
                                cmd_file.unlink()
                                with open(status_file, "w") as f:
                                    json.dump({"status": "stopped"}, f)
                                return

                            elif cmd_type == "INTERVIEW":
                                agent_id = payload.get("agent_id")
                                prompt = payload.get("prompt", "")
                                response = {
                                    "success": True,
                                    "result": f"[Agent {agent_id}] Interview response to: {prompt}"
                                }
                                with open(responses_dir / f"{command_id}.json", "w") as f:
                                    json.dump(response, f)

                            cmd_file.unlink()

                        except Exception as e:
                            print(f"IPC error: {e}", file=sys.stderr)

                    await asyncio.sleep(0.5)


            def main():
                parser = argparse.ArgumentParser(description="NewsComb OASIS Simulation")
                parser.add_argument("--config", required=True, help="Path to simulation_config.json")
                parser.add_argument("--max-rounds", type=int, help="Override max rounds")
                args = parser.parse_args()

                sim_dir = Path(args.config).parent
                config = load_config(args.config)

                if args.max_rounds:
                    config["max_rounds"] = args.max_rounds

                asyncio.run(run_simulation(sim_dir, config))


            if __name__ == "__main__":
                main()
            """

        let filePath = directory.appending(path: "run_simulation.py")
        try script.write(to: filePath, atomically: true, encoding: .utf8)

        // Make executable
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: filePath.path(percentEncoded: false)
        )
    }

    // MARK: - Helpers

    private func sanitizeCSV(_ value: String) -> String {
        let escaped = value.replacing("\"", with: "\"\"")
        if escaped.contains(",") || escaped.contains("\"") || escaped.contains("\n") {
            return "\"\(escaped)\""
        }
        return escaped
    }
}

// MARK: - Errors

enum OasisExportError: LocalizedError {
    case noAgents

    var errorDescription: String? {
        switch self {
        case .noAgents:
            "No agents to export. Generate agent profiles first."
        }
    }
}
