import SwiftUI

struct ContentView: View {

    private let coordinator = WorkspaceCoordinator.shared

    var body: some View {
        MainView()
            .navigationTitle(coordinator.active.map { "NewsComb — \($0.name)" } ?? "NewsComb")
            #if os(macOS)
            .sheet(isPresented: Binding(
                get: { coordinator.active == nil },
                set: { _ in }
            )) {
                FirstRunWorkspaceSheet(coordinator: coordinator) { url in
                    try? coordinator.openWorkspace(at: url)
                }
                .interactiveDismissDisabled(true)
            }
            #endif
    }
}

#Preview {
    ContentView()
}
