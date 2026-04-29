import OSLog
import SwiftUI

@main
struct NewsCombApp: App {

    init() {
        let logger = Logger(subsystem: "com.newscomb.app", category: "Launch")

        // Resolve the active workspace before any code reads Database.current.
        // Resolution order: --workspace arg > NEWSCOMB_WORKSPACE env >
        // last-opened (UserDefaults) > legacy ~/Library/Application Support DB.
        do {
            let result = try WorkspaceCoordinator.shared.bootstrap()
            switch result {
            case .opened(let workspace, let source):
                logger.notice("Bootstrapped workspace '\(workspace.name, privacy: .public)' from \(String(describing: source), privacy: .public)")
            case .needsSelection:
                logger.notice("No workspace configured at launch; ContentView will show first-run picker")
            }
        } catch let bootError as WorkspaceCoordinator.BootstrapError {
            // Explicit-source failure (CLI arg / env var). Record on the
            // coordinator so ContentView can present an alert; Database.current's
            // lazy fallback keeps the app functional in the meantime.
            logger.error("Workspace bootstrap failed: \(bootError.errorDescription ?? "unknown", privacy: .public)")
            WorkspaceCoordinator.shared.recordBootstrapError(bootError)
        } catch {
            logger.error("Workspace bootstrap failed: \(error.localizedDescription, privacy: .public)")
        }

        // Start the MCP stdio server on a background task.
        // AI assistants (Claude Code, Claude Desktop) can connect via stdio transport.
        MCPServerService.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        #if os(macOS)
        .commands {
            WorkspaceCommands(coordinator: WorkspaceCoordinator.shared)
        }
        #endif

        #if os(macOS)
        Settings {
            SettingsView()
        }

        Window("Knowledge Graph", id: "graph-visualization") {
            GraphVisualizationView()
        }
        .defaultSize(width: 1200, height: 800)

        WindowGroup("Focused Graph", id: "focused-graph", for: Int64.self) { $nodeId in
            GraphVisualizationView(focusedNodeId: nodeId)
        }
        .defaultSize(width: 1000, height: 700)
        #endif
    }
}
