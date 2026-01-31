import SwiftUI

/// Displays a single story theme with its top entities, exemplar events, and full member list.
struct ThemeDetailView: View {
    @State private var viewModel: ThemeDetailViewModel

    init(cluster: StoryCluster) {
        _viewModel = State(initialValue: ThemeDetailViewModel(cluster: cluster))
    }

    var body: some View {
        List {
            overviewSection
            topEntitiesSection
            topRelFamiliesSection
            exemplarsSection

            if !viewModel.allMembersLoaded {
                loadAllSection
            } else if !viewModel.memberEvents.isEmpty {
                allMembersSection
            }
        }
        .navigationTitle(viewModel.cluster.label ?? "Theme")
        .onAppear {
            viewModel.loadExemplars()
        }
    }

    // MARK: - Sections

    private var overviewSection: some View {
        Section {
            if let summary = viewModel.cluster.summary {
                Text(summary)
            }

            LabeledContent("Events", value: "\(viewModel.cluster.size)")

            if let date = viewModel.cluster.createdAt as Date? {
                LabeledContent("Computed") {
                    Text(date, style: .relative)
                    Text("ago")
                }
            }
        } header: {
            Text("Overview")
        }
    }

    private var topEntitiesSection: some View {
        Section {
            let entities = viewModel.cluster.topEntities
            if entities.isEmpty {
                Text("No entity data available")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(entities.prefix(15)) { entity in
                    HStack {
                        Text(entity.label)
                        Spacer()
                        Text(entity.score, format: .number.precision(.fractionLength(1)))
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                }
            }
        } header: {
            Label("Top Entities", systemImage: "person.3")
        }
    }

    private var topRelFamiliesSection: some View {
        Section {
            let families = viewModel.cluster.topRelFamilies
            if families.isEmpty {
                Text("No relation data available")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(families) { family in
                    HStack {
                        Text(family.family)
                        Spacer()
                        Text("\(family.count)")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                }
            }
        } header: {
            Label("Relation Types", systemImage: "arrow.triangle.branch")
        }
    }

    private var exemplarsSection: some View {
        Section {
            if viewModel.exemplarEvents.isEmpty {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading exemplars\u{2026}")
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(viewModel.exemplarEvents) { event in
                    EventRow(event: event)
                }
            }
        } header: {
            Label("Key Events", systemImage: "star")
        }
    }

    private var loadAllSection: some View {
        Section {
            Button("Load All \(viewModel.cluster.size) Events", systemImage: "arrow.down.circle") {
                viewModel.loadAllMembers()
            }
        }
    }

    private var allMembersSection: some View {
        Section {
            ForEach(viewModel.memberEvents) { event in
                EventRow(event: event)
            }
        } header: {
            Label("All Events (\(viewModel.memberEvents.count))", systemImage: "list.bullet")
        }
    }
}

// MARK: - Event Row

private struct EventRow: View {
    let event: ThemeDetailViewModel.EventDisplay

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // S-V-O sentence
            Text(event.sentence)
                .font(.subheadline)

            // Participants as chips
            HStack(spacing: 4) {
                ForEach(event.sources, id: \.self) { source in
                    Text(source)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.blue.opacity(0.12))
                        .foregroundStyle(.blue)
                        .clipShape(.capsule)
                }

                if !event.targets.isEmpty {
                    Image(systemName: "arrow.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    ForEach(event.targets, id: \.self) { target in
                        Text(target)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.green.opacity(0.12))
                            .foregroundStyle(.green)
                            .clipShape(.capsule)
                    }
                }
            }

            // Provenance
            if let title = event.articleTitle {
                HStack(spacing: 4) {
                    Image(systemName: "doc.text")
                        .font(.caption2)
                    Text(title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
