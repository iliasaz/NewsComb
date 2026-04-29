import SwiftUI

struct ContentView: View {

    private let coordinator = WorkspaceCoordinator.shared

    var body: some View {
        MainView()
            .navigationTitle(coordinator.active.map { "NewsComb — \($0.name)" } ?? "NewsComb")
            #if os(macOS)
            .alert(
                "Couldn't open workspace",
                isPresented: Binding(
                    get: { coordinator.bootstrapError != nil },
                    set: { newValue in
                        if !newValue {
                            coordinator.clearBootstrapError()
                        }
                    }
                ),
                presenting: coordinator.bootstrapError
            ) { _ in
                Button("OK", role: .cancel) {
                    coordinator.clearBootstrapError()
                }
            } message: { state in
                let path = state.directory.path(percentEncoded: false)
                Text(path + "\n\n" + state.message)
            }
            // First-run sheet stays suppressed while the alert is up so the
            // two presentations don't collide.
            .sheet(isPresented: Binding(
                get: { coordinator.active == nil && coordinator.bootstrapError == nil },
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
