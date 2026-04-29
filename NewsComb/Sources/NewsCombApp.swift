import SwiftUI
import NewsComb
#if canImport(AppKit)
import AppKit
#endif

@main
struct NewsCombApp: App {
    init() {
        // Database is initialized lazily via Database.current
        _ = Database.current

        #if canImport(AppKit)
        // Activate the app and bring it to front
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
