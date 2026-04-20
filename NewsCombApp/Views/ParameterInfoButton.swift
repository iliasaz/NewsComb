import SwiftUI

/// Small `info.circle` button that opens a popover with a detailed parameter description.
/// Reusable across Settings rows so each tunable knob can carry inline help.
struct ParameterInfoButton: View {
    let title: String
    let description: String

    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .help(title)
        .popover(isPresented: $isPresented, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .bold()
                Text(description)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding()
            .frame(maxWidth: 360, alignment: .leading)
        }
    }
}

#Preview {
    Form {
        HStack {
            Text("HDBSCAN Min Cluster Size")
            ParameterInfoButton(
                title: "HDBSCAN Min Cluster Size",
                description: "Smallest group of events HDBSCAN will treat as a real cluster. Anything smaller is merged or marked as noise."
            )
            Spacer()
            Text("Auto")
                .foregroundStyle(.secondary)
        }
    }
}
