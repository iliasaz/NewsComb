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
                arguments: [simDir.path(), simulationId]
            )
        }

        logger.info("Export complete to \(simDir.path(), privacy: .public)")
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
        let configDict: [String: Any] = [
            "max_rounds": config.maxRounds,
            "minutes_per_round": config.minutesPerRound,
            "platforms": config.platforms,
            "agents_per_hour_min": config.agentsPerHourMin,
            "agents_per_hour_max": config.agentsPerHourMax,
            "agent_count": agentCount,
            "semaphore_limit": config.semaphoreLimit
        ]

        let data = try JSONSerialization.data(withJSONObject: configDict, options: [.prettyPrinted, .sortedKeys])
        let filePath = directory.appending(path: "simulation_config.json")
        try data.write(to: filePath)
    }

    // MARK: - Script Generation

    private func generateSimulationScript(config: SimulationConfig, to directory: URL) throws {
        let script = """
            #!/usr/bin/env python3
            \"\"\"
            OASIS social simulation script generated by NewsComb.
            Runs the simulation and enters IPC wait mode for interviews.
            \"\"\"
            import argparse
            import asyncio
            import json
            import os
            import sys
            import time
            from pathlib import Path

            # Ensure OASIS is importable
            try:
                from oasis import OasisEnv
                from oasis.social_platform.platform import Platform
                from oasis.social_agent.agents_generator import generate_agents
            except ImportError:
                print("ERROR: camel-oasis not installed. Run: pip install camel-oasis==0.2.5", file=sys.stderr)
                sys.exit(1)


            def load_config(config_path):
                with open(config_path) as f:
                    return json.load(f)


            async def run_simulation(sim_dir, config):
                \"\"\"Run the OASIS simulation loop.\"\"\"
                platforms = config.get("platforms", ["twitter"])
                max_rounds = config.get("max_rounds", 72)
                semaphore = config.get("semaphore_limit", 128)

                # TODO: Initialize OASIS environment with profiles
                # This template needs to be customized based on OASIS version and profile format.
                # See MiraFish's run_parallel_simulation.py for reference.

                print(f"Simulation would run {max_rounds} rounds on {platforms}")
                print(f"Semaphore limit: {semaphore}")
                print(f"Working directory: {sim_dir}")

                # Placeholder: write action log entries
                for platform in platforms:
                    actions_file = sim_dir / platform / "actions.jsonl"
                    with open(actions_file, "w") as f:
                        f.write(json.dumps({"event_type": "simulation_start"}) + "\\n")

                    # Simulation rounds would go here
                    for round_num in range(max_rounds):
                        with open(actions_file, "a") as f:
                            f.write(json.dumps({
                                "event_type": "round_end",
                                "round": round_num
                            }) + "\\n")

                    with open(actions_file, "a") as f:
                        f.write(json.dumps({"event_type": "simulation_end"}) + "\\n")

                print("Simulation complete. Entering IPC wait mode...")
                await ipc_wait_mode(sim_dir)


            async def ipc_wait_mode(sim_dir):
                \"\"\"Poll for IPC commands (interviews, close).\"\"\"
                commands_dir = sim_dir / "ipc_commands"
                responses_dir = sim_dir / "ipc_responses"

                # Write status file
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
                                # Write response and exit
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
                                # TODO: Route to actual OASIS agent interview
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
            ofItemAtPath: filePath.path()
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
