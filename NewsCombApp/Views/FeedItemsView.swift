import SwiftUI

struct FeedItemsView: View {
    @State private var viewModel = FeedItemsViewModel()
    let sourceId: Int64?
    let sourceName: String?

    init(sourceId: Int64? = nil, sourceName: String? = nil) {
        self.sourceId = sourceId
        self.sourceName = sourceName
    }

    var body: some View {
        List {
            ForEach(viewModel.filteredItems) { item in
                NavigationLink(value: item) {
                    FeedItemRow(item: item)
                }
            }
        }
        .navigationTitle(sourceName ?? "All Articles")
        .navigationDestination(for: FeedItemDisplay.self) { item in
            FeedItemDetailView(item: item)
        }
        .searchable(text: $viewModel.searchText, prompt: "Search articles")
        .refreshable {
            await viewModel.refresh()
        }
        .overlay {
            if viewModel.isLoading && viewModel.items.isEmpty {
                ProgressView("Loading articles...")
            } else if viewModel.items.isEmpty {
                ContentUnavailableView(
                    "No Articles",
                    systemImage: "doc.text",
                    description: Text("Refresh feeds to fetch new articles.")
                )
            }
        }
        .onAppear {
            if let sourceId {
                viewModel.loadItems(forSourceId: sourceId)
            } else {
                viewModel.loadItems()
            }
        }
        .alert("Error", isPresented: .init(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )) {
            Button("OK") { viewModel.errorMessage = nil }
        } message: {
            if let error = viewModel.errorMessage {
                Text(error)
            }
        }
    }
}

struct FeedItemRow: View {
    let item: FeedItemDisplay

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(item.sourceName)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                if !item.displayDate.isEmpty {
                    Text(item.displayDate)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Text(item.title)
                .font(.headline)
                .lineLimit(2)

            if !item.snippet.isEmpty {
                Text(item.snippet)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            HStack {
                if let author = item.author, !author.isEmpty {
                    Label(author, systemImage: "person")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                if item.hasFullContent {
                    Label("Full article", systemImage: "doc.text.fill")
                        .font(.caption2)
                        .foregroundStyle(.blue)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    NavigationStack {
        FeedItemsView()
    }
}
