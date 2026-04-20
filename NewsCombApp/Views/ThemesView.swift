import SwiftUI

/// Displays the list of story themes (clusters) with a rebuild action.
struct ThemesView: View {
    @State private var viewModel = ThemeClusterViewModel.shared
    @State private var dropConfirmAlert: DropConfirmAlert?

    private struct DropConfirmAlert: Identifiable {
        let id = UUID()
        let ids: [Int64]
        let summary: String
    }

    private func confirmDropNoisePools() {
        let ids = Array(viewModel.noisePoolClusterIds)
        guard !ids.isEmpty else { return }
        let lookup = Dictionary(uniqueKeysWithValues: viewModel.clusters.map { ($0.clusterId, $0) })
        let summary = ids
            .compactMap { id -> String? in
                guard let c = lookup[id] else { return nil }
                return "#\(id) (\(c.size) events)"
            }
            .joined(separator: ", ")
        dropConfirmAlert = DropConfirmAlert(
            ids: ids,
            summary: "Drop \(ids.count) noise-pool cluster(s): \(summary)? Saved sub-themes will be unlinked and become top-level. Underlying article and graph data is preserved."
        )
    }

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

                        Divider()

                        Button("Drop Noise Pool Clusters\u{2026}", systemImage: "trash", role: .destructive) {
                            confirmDropNoisePools()
                        }
                        .disabled(viewModel.noisePoolClusterIds.isEmpty)
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
        .alert(item: $dropConfirmAlert) { alert in
            Alert(
                title: Text("Drop Noise Pools"),
                message: Text(alert.summary),
                primaryButton: .destructive(Text("Drop")) {
                    Task { _ = await viewModel.dropNoisePools(ids: alert.ids) }
                },
                secondaryButton: .cancel()
            )
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
            if !viewModel.noisePoolClusterIds.isEmpty {
                LabeledContent("Noise Pools (outliers)", value: "\(viewModel.noisePoolClusterIds.count)")
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Summary")
        }
    }

    private var clustersSection: some View {
        Section {
            if viewModel.isSearching {
                // Flat list for search — entries can be either top-level or children.
                ForEach(viewModel.displayedClusters) { cluster in
                    NavigationLink(value: cluster) {
                        ClusterRow(
                            cluster: cluster,
                            snippet: viewModel.snippet(for: cluster.clusterId),
                            isSplitting: viewModel.splittingClusterIds.contains(cluster.clusterId),
                            isNoisePool: viewModel.noisePoolClusterIds.contains(cluster.clusterId)
                        )
                    }
                }
            } else {
                // Tree view: top-level rows + DisclosureGroup-expanded children.
                ForEach(viewModel.topLevelClusters) { parent in
                    let children = viewModel.subClusters(of: parent.clusterId)
                    if children.isEmpty {
                        NavigationLink(value: parent) {
                            ClusterRow(
                                cluster: parent,
                                snippet: nil,
                                isSplitting: viewModel.splittingClusterIds.contains(parent.clusterId),
                                isNoisePool: viewModel.noisePoolClusterIds.contains(parent.clusterId)
                            )
                        }
                    } else {
                        ParentClusterRow(
                            parent: parent,
                            children: children,
                            isSplitting: viewModel.splittingClusterIds.contains(parent.clusterId),
                            isNoisePool: viewModel.noisePoolClusterIds.contains(parent.clusterId)
                        )
                    }
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
    /// True when this cluster's split is currently running. Adds an animated indicator + tint.
    var isSplitting: Bool = false
    /// True when this cluster is a statistical outlier (likely an absorption pool, not a real theme).
    var isNoisePool: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("#\(cluster.clusterId)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)

                Text(cluster.label ?? "Untitled")
                    .font(.headline)
                    .lineLimit(1)
                    .italic(cluster.isTentative)

                if cluster.isTentative {
                    Text("tentative")
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.orange.opacity(0.18))
                        .foregroundStyle(.orange)
                        .clipShape(.capsule)
                }

                if isNoisePool {
                    Text("noise pool")
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.red.opacity(0.16))
                        .foregroundStyle(.red)
                        .clipShape(.capsule)
                }

                if isSplitting {
                    ProgressView()
                        .controlSize(.small)
                }

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
        .listRowBackground(rowBackground)
    }

    private var rowBackground: AnyView? {
        if isSplitting {
            return AnyView(Color.yellow.opacity(0.15))
        }
        if isNoisePool {
            return AnyView(Color.red.opacity(0.06))
        }
        if cluster.isTentative {
            return AnyView(Color.orange.opacity(0.06))
        }
        return nil
    }
}

// MARK: - Parent Cluster Row (DisclosureGroup wrapper)

private struct ParentClusterRow: View {
    let parent: StoryCluster
    let children: [StoryCluster]
    let isSplitting: Bool
    let isNoisePool: Bool

    @State private var isExpanded: Bool = true

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            ForEach(children) { child in
                NavigationLink(value: child) {
                    ClusterRow(cluster: child, snippet: nil, isSplitting: false, isNoisePool: false)
                }
            }
        } label: {
            NavigationLink(value: parent) {
                ClusterRow(cluster: parent, snippet: nil, isSplitting: isSplitting, isNoisePool: isNoisePool)
            }
        }
    }
}

#Preview {
    NavigationStack {
        ThemesView()
    }
}
