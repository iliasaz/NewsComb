import SwiftUI

/// Sheet for extracting a focused theme by free-text phrase from a parent cluster.
/// The result is a tentative child handled by the existing Save/Discard/Delete flow.
struct ExtractThemeSheet: View {
    let parentSize: Int
    let onCommit: (_ query: String, _ topK: Int, _ threshold: Float) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query: String = ""
    @State private var topK: Int = 200
    @State private var threshold: Float = 0.45
    @FocusState private var queryFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("e.g. Google Spanner BigQuery", text: $query, axis: .vertical)
                        .lineLimit(1...3)
                        .focused($queryFocused)
                } header: {
                    Text("Phrase")
                } footer: {
                    Text("The phrase is embedded with the same model as the chunk index. Events whose source chunk is semantically close to the phrase are included.")
                }

                Section {
                    Stepper(value: $topK, in: 10...1000, step: 10) {
                        HStack {
                            Text("Max events")
                            Spacer()
                            Text("\(topK)")
                                .foregroundStyle(.secondary)
                        }
                    }

                    HStack {
                        Text("Similarity threshold")
                        Spacer()
                        Text(threshold, format: .number.precision(.fractionLength(2)))
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $threshold, in: 0.30...0.80, step: 0.05)
                } header: {
                    Text("Limits")
                } footer: {
                    Text("Higher threshold = stricter matching, fewer events. Parent has \(parentSize) events.")
                }

                Section {
                    Button("Extract", systemImage: "text.magnifyingglass") {
                        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        onCommit(trimmed, topK, threshold)
                        dismiss()
                    }
                    .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Extract Theme")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear { queryFocused = true }
        }
        .frame(minWidth: 520, idealWidth: 580, minHeight: 420, idealHeight: 460)
    }
}

#Preview {
    ExtractThemeSheet(parentSize: 53885) { q, k, t in
        print("extract '\(q)' topK=\(k) threshold=\(t)")
    }
}
