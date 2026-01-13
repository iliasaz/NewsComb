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
        #endif
    }
}
