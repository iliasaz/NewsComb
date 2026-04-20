import SwiftUI

/// Sheet for choosing custom HDBSCAN parameters when splitting a cluster.
/// Splits are non-destructive — they create tentative children that the user later
/// saves or discards via the parent's Actions menu.
struct SplitParametersSheet: View {
    let memberCount: Int
    let onCommit: (_ minClusterSize: Int?, _ minSamples: Int?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var minClusterSize: Int
    @State private var minSamples: Int = 10

    init(memberCount: Int, onCommit: @escaping (Int?, Int?) -> Void) {
        self.memberCount = memberCount
        self.onCommit = onCommit
        _minClusterSize = State(initialValue: max(20, Int(Double(memberCount).squareRoot() / 4)))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Stepper(value: $minClusterSize, in: 5...500, step: 5) {
                        HStack {
                            Text("Min Cluster Size")
                            Spacer()
                            Text("\(minClusterSize)")
                                .foregroundStyle(.secondary)
                        }
                    }
                    Stepper(value: $minSamples, in: 2...50) {
                        HStack {
                            Text("Min Samples")
                            Spacer()
                            Text("\(minSamples)")
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Parameters")
                } footer: {
                    Text("Splitting \(memberCount) events. Lower Min Cluster Size produces more, smaller sub-themes; higher values produce fewer, broader ones. Sub-themes appear as tentative children — save or discard them later.")
                }

                Section {
                    Button("Run Split", systemImage: "scissors") {
                        onCommit(minClusterSize, minSamples)
                        dismiss()
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Split Cluster")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .frame(minWidth: 520, idealWidth: 560, minHeight: 360, idealHeight: 400)
    }
}

#Preview {
    SplitParametersSheet(memberCount: 53885) { minSize, minSamples in
        print("commit: minSize=\(String(describing: minSize)) minSamples=\(String(describing: minSamples))")
    }
}
