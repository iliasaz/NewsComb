import SwiftUI

@main
struct NewsCombApp: App {
    init() {
        // Database is initialized lazily via Database.shared
        _ = Database.shared
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }

        #if os(macOS)
        Settings {
            SettingsView()
        }

        Window("Knowledge Graph", id: "graph-visualization") {
            GraphVisualizationView()
        }
        .defaultSize(width: 1200, height: 800)
        #endif
    }
}
