import SwiftUI

public struct ContentView: View {
    public init() {}

    public var body: some View {
        TabView {
            Tab("Feeds", systemImage: "newspaper") {
                MainView()
            }

            Tab("Settings", systemImage: "gear") {
                SettingsView()
            }
        }
    }
}

#Preview {
    ContentView()
}
