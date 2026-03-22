import SwiftUI

/// Displays the list of story themes (clusters) with a rebuild action.
struct ThemesView: View {
    @State private var viewModel = ThemeClusterViewModel()

    var body: some View {
        List {
            if viewModel.isRebuilding {
                rebuildProgressSection
            }

            if viewModel.hasClusters {
                if !viewModel.isSearching {
                    statsSection
                }
                clustersSection
            }
        }
        .searchable(text: $viewModel.searchText, prompt: "Search themes")
        .navigationTitle("Story Themes")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if viewModel.isRebuilding {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Menu {
                        Button("Recompute All", systemImage: "arrow.triangle.2.circlepath") {
                            Task {
                                await viewModel.rebuildClusters()
                            }
                        }

                        Button("Regenerate Summaries", systemImage: "text.badge.star") {
                            Task {
                                await viewModel.regenerateSummaries()
                            }
                        }
                        .disabled(!viewModel.hasClusters)
                    } label: {
                        Label("Actions", systemImage: "ellipsis.circle")
                    }
                }
            }
        }
        .overlay {
            if !viewModel.hasClusters && !viewModel.isRebuilding {
                ContentUnavailableView {
                    Label("No Themes", systemImage: "rectangle.3.group")
                } description: {
                    Text("Tap Recompute to cluster your knowledge graph into story themes.")
                } actions: {
                    Button("Recompute Themes") {
                        Task {
                            await viewModel.rebuildClusters()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .alert("Clustering Error", isPresented: .init(
            get: { viewModel.rebuildError != nil },
            set: { if !$0 { viewModel.clearError() } }
        )) {
            Button("OK") { viewModel.clearError() }
        } message: {
            if let error = viewModel.rebuildError {
                Text(error)
            }
        }
        .onAppear {
            viewModel.loadClusters()
        }
    }

    // MARK: - Sections

    private var rebuildProgressSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text(viewModel.rebuildStatus.isEmpty ? "Starting\u{2026}" : viewModel.rebuildStatus)
                        .foregroundStyle(.secondary)
                }

                if viewModel.rebuildProgress > 0 {
                    ProgressView(value: viewModel.rebuildProgress)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var statsSection: some View {
        Section {
            LabeledContent("Themes", value: "\(viewModel.clusters.count)")
            LabeledContent("Clustered Events", value: "\(viewModel.totalEvents - viewModel.noiseCount)")
            if viewModel.noiseCount > 0 {
                LabeledContent("Noise Events", value: "\(viewModel.noiseCount)")
            }
        } header: {
            Text("Summary")
        }
    }

    private var clustersSection: some View {
        Section {
            ForEach(viewModel.displayedClusters) { cluster in
                NavigationLink(value: cluster) {
                    ClusterRow(
                        cluster: cluster,
                        snippet: viewModel.snippet(for: cluster.clusterId)
                    )
                }
            }
        } header: {
            if viewModel.isSearching {
                Text("\(viewModel.searchResults.count) results")
            } else {
                Text("Themes")
            }
        }
    }
}

// MARK: - Cluster Row

private struct ClusterRow: View {
    let cluster: StoryCluster
    var snippet: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(cluster.label ?? "Cluster \(cluster.clusterId)")
                    .font(.headline)
                    .lineLimit(1)

                Spacer()

                Text("\(cluster.size)")
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(.secondary.opacity(0.15))
                    .clipShape(.capsule)
            }

            if let snippet {
                HighlightedSnippet(snippet: snippet)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            } else if let summary = cluster.summary {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            // Top entities as chips
            let entities = cluster.topEntities.prefix(5)
            if !entities.isEmpty {
                HStack(spacing: 4) {
                    ForEach(entities) { entity in
                        Text(entity.label)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.blue.opacity(0.12))
                            .foregroundStyle(.blue)
                            .clipShape(.capsule)
                            .lineLimit(1)
                    }
                }
            }

            // Top relation family
            if let topFamily = cluster.topRelFamilies.first {
                Text(topFamily.family)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    NavigationStack {
        ThemesView()
    }
}
