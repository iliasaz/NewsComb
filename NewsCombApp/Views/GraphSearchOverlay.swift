import SwiftUI

/// Floating search overlay for the graph visualization canvas.
///
/// Provides a search bar at the top of the graph view and a results panel
/// listing matched concepts — both direct label matches and nodes derived
/// from matching article content.
struct GraphSearchOverlay: View {
    @Bindable var viewModel: GraphViewModel

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            if viewModel.showSearchResults, let results = viewModel.searchResults {
                resultsPanel(results)
            }
            Spacer()
        }
        .padding()
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Search graph...", text: $viewModel.searchText)
                .textFieldStyle(.plain)
                .onSubmit {
                    viewModel.performSearch()
                }
                .onChange(of: viewModel.searchText) {
                    viewModel.performSearch()
                }

            if viewModel.isSearching {
                ProgressView()
                    .controlSize(.small)
            }

            if !viewModel.searchText.isEmpty {
                Button("Clear", systemImage: "xmark.circle.fill") {
                    viewModel.clearSearch()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .frame(maxWidth: 400)
    }

    // MARK: - Results Panel

    private func resultsPanel(_ results: GraphSearchResults) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Summary header
            HStack {
                Text("\(results.totalCount) result\(results.totalCount == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Close", systemImage: "xmark") {
                    viewModel.showSearchResults = false
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    // Direct label matches
                    if !results.nodeMatches.isEmpty {
                        nodeMatchesSection(
                            title: "Concepts",
                            matches: results.nodeMatches
                        )
                    }

                    // Nodes found via article content
                    if !results.contentDerivedNodes.isEmpty {
                        nodeMatchesSection(
                            title: "Found in Articles",
                            matches: results.contentDerivedNodes
                        )
                    }
                }
                .padding(8)
            }
            .frame(maxHeight: 300)
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .frame(maxWidth: 400)
        .padding(.top, 4)
    }

    // MARK: - Section Views

    private func nodeMatchesSection(title: String, matches: [FTSNodeMatch]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .bold()

            ForEach(matches) { match in
                NodeMatchRow(match: match) {
                    viewModel.loadNodeProvenance(nodeId: match.id)
                }
            }
        }
    }
}

// MARK: - Row Views

/// A single node match row in the search results panel.
private struct NodeMatchRow: View {
    let match: FTSNodeMatch
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 8) {
                Circle()
                    .fill(.yellow)
                    .frame(width: 8, height: 8)
                    .padding(.top, 4)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(match.label)
                            .font(.callout)
                            .bold()
                            .lineLimit(1)

                        if let nodeType = match.nodeType {
                            Text(nodeType)
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.quaternary, in: Capsule())
                        }
                    }

                    if let articleTitle = match.articleTitle {
                        Text("From: \(articleTitle)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }

                    HighlightedSnippet(snippet: match.snippet)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
