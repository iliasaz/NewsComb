import SwiftUI

/// Displays a single story theme with its top entities, exemplar events, and full member list.
struct ThemeDetailView: View {
    @State private var viewModel: ThemeDetailViewModel
    @State private var themesViewModel = ThemeClusterViewModel.shared
    @State private var showingCustomSplitSheet = false
    @State private var showingExtractSheet = false
    @State private var alertState: AlertState?
    @Environment(\.dismiss) private var dismiss

    /// Single alert state. Chaining two `.alert(item:)` modifiers on the same view is a known
    /// SwiftUI pitfall — only the last one observes its binding, so the second never appears.
    /// We use one alert with an enum to switch between confirm and result presentations.
    private enum AlertState: Identifiable {
        case confirm(PendingConfirm)
        case result(ResultAlert)

        var id: UUID {
            switch self {
            case .confirm(let c): return c.id
            case .result(let r): return r.id
            }
        }
    }

    /// Confirmation prompt shown before a destructive action (Save / Discard / Delete).
    private struct PendingConfirm: Identifiable {
        let id = UUID()
        let title: String
        let message: String
        let actionLabel: String
        let isDestructive: Bool
        let perform: () async -> Void
    }

    /// Result message shown after an action completes (info-only, single OK button).
    private struct ResultAlert: Identifiable {
        let id = UUID()
        let title: String
        let message: String
        /// If true, the OK action also dismisses the detail view.
        let dismissOnOK: Bool
    }

    init(cluster: StoryCluster) {
        _viewModel = State(initialValue: ThemeDetailViewModel(cluster: cluster))
    }

    private var liveCluster: StoryCluster {
        themesViewModel.clusters.first { $0.clusterId == viewModel.cluster.clusterId } ?? viewModel.cluster
    }

    var body: some View {
        List {
            overviewSection
            tentativeChildrenSection
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
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                actionsMenu
            }
        }
        .sheet(isPresented: $showingCustomSplitSheet) {
            SplitParametersSheet(
                memberCount: viewModel.cluster.size,
                onCommit: { minSize, minSamples in
                    Task { await runSplit(minClusterSize: minSize, minSamples: minSamples) }
                }
            )
        }
        .sheet(isPresented: $showingExtractSheet) {
            ExtractThemeSheet(
                parentSize: viewModel.cluster.size,
                onCommit: { query, topK, threshold in
                    Task { await runExtract(query: query, topK: topK, threshold: threshold) }
                }
            )
        }
        .alert(item: $alertState) { state in
            switch state {
            case .confirm(let confirm):
                return Alert(
                    title: Text(confirm.title),
                    message: Text(confirm.message),
                    primaryButton: confirm.isDestructive
                        ? .destructive(Text(confirm.actionLabel)) { Task { await confirm.perform() } }
                        : .default(Text(confirm.actionLabel)) { Task { await confirm.perform() } },
                    secondaryButton: .cancel()
                )
            case .result(let alert):
                return Alert(
                    title: Text(alert.title),
                    message: Text(alert.message),
                    dismissButton: .default(Text("OK")) {
                        if alert.dismissOnOK { dismiss() }
                    }
                )
            }
        }
        .onAppear {
            viewModel.loadExemplars()
        }
    }

    // MARK: - Actions Menu

    private var actionsMenu: some View {
        Menu {
            // Split actions: only meaningful for top-level clusters with no pending split.
            let isParent = liveCluster.parentClusterId == nil
            let hasTentative = themesViewModel.hasTentativeChildren(liveCluster.clusterId)

            if isParent && !hasTentative {
                Section("Split") {
                    Button("Split (Auto)", systemImage: "scissors") {
                        Task { await runSplit(minClusterSize: nil, minSamples: nil) }
                    }
                    Button("Split (Aggressive: min=20)", systemImage: "scissors.badge.ellipsis") {
                        Task { await runSplit(minClusterSize: 20, minSamples: nil) }
                    }
                    Button("Split with Custom Parameters\u{2026}", systemImage: "slider.horizontal.3") {
                        showingCustomSplitSheet = true
                    }
                    Button("Extract Theme by Phrase\u{2026}", systemImage: "text.magnifyingglass") {
                        showingExtractSheet = true
                    }
                }
            }

            if hasTentative {
                Section("Pending Split") {
                    Button("Save Split", systemImage: "checkmark.circle") {
                        confirmSaveSplit()
                    }
                    Button("Discard Split", systemImage: "xmark.circle", role: .destructive) {
                        confirmDiscardSplit()
                    }
                }
            }

            Section("Cluster") {
                Button("Delete Cluster\u{2026}", systemImage: "trash", role: .destructive) {
                    confirmDeleteCluster()
                }
            }
        } label: {
            Label("Actions", systemImage: "ellipsis.circle")
        }
        .disabled(themesViewModel.isRebuilding)
    }

    // MARK: - Action Handlers

    private func confirmSaveSplit() {
        let children = themesViewModel.subClusters(of: liveCluster.clusterId).filter(\.isTentative)
        alertState = .confirm(PendingConfirm(
            title: "Save Split",
            message: "Promote \(children.count) tentative sub-theme(s) to permanent. The parent cluster stays unchanged.",
            actionLabel: "Save",
            isDestructive: false,
            perform: {
                let result = await themesViewModel.saveSplit(parent: liveCluster)
                presentResult(for: result, verb: "Saved", noun: "sub-theme(s) promoted", dismissOnOK: false)
            }
        ))
    }

    private func confirmDiscardSplit() {
        let children = themesViewModel.subClusters(of: liveCluster.clusterId).filter(\.isTentative)
        alertState = .confirm(PendingConfirm(
            title: "Discard Split",
            message: "Remove \(children.count) tentative sub-theme(s)? The parent cluster stays unchanged.",
            actionLabel: "Discard",
            isDestructive: true,
            perform: {
                let result = await themesViewModel.discardSplit(parent: liveCluster)
                presentResult(for: result, verb: "Discarded", noun: "tentative sub-theme(s) removed", dismissOnOK: false)
            }
        ))
    }

    private func confirmDeleteCluster() {
        let savedChildren = themesViewModel.subClusters(of: liveCluster.clusterId).filter { !$0.isTentative }
        let tentativeChildren = themesViewModel.subClusters(of: liveCluster.clusterId).filter(\.isTentative)

        let message: String
        let totalChildren = savedChildren.count + tentativeChildren.count
        if totalChildren > 0 {
            var parts: [String] = ["This cluster has \(totalChildren) sub-theme(s). They will be unlinked and become top-level themes."]
            if !tentativeChildren.isEmpty {
                parts.append("(\(tentativeChildren.count) of them are tentative — they will be promoted to regular themes since there's no parent left to save/discard against.)")
            }
            parts.append("Underlying article and graph data is preserved.")
            message = parts.joined(separator: " ")
        } else {
            message = "Remove cluster #\(liveCluster.clusterId) from the database. Underlying article and graph data is preserved."
        }

        alertState = .confirm(PendingConfirm(
            title: "Delete Cluster",
            message: message,
            actionLabel: "Delete",
            isDestructive: true,
            perform: {
                let result = await themesViewModel.deleteCluster(liveCluster)
                switch result {
                case .success(let res):
                    var parts: [String] = ["Cluster #\(liveCluster.clusterId) deleted."]
                    if res.unlinkedChildCount > 0 {
                        parts.append("\(res.unlinkedChildCount) sub-theme(s) unlinked and promoted to top-level.")
                    }
                    if res.promotedTentativeChildCount > 0 {
                        parts.append("(\(res.promotedTentativeChildCount) of them were tentative and are now regular themes.)")
                    }
                    alertState = .result(ResultAlert(
                        title: "Deleted",
                        message: parts.joined(separator: " "),
                        dismissOnOK: true
                    ))
                case .failure(let error):
                    alertState = .result(ResultAlert(title: "Delete Failed", message: error.message, dismissOnOK: false))
                }
            }
        ))
    }

    private func presentResult(for result: Result<Int, ThemeOperationError>, verb: String, noun: String, dismissOnOK: Bool) {
        switch result {
        case .success(let count):
            alertState = .result(ResultAlert(
                title: verb,
                message: "\(count) \(noun).",
                dismissOnOK: dismissOnOK
            ))
        case .failure(let error):
            alertState = .result(ResultAlert(title: "\(verb) Failed", message: error.message, dismissOnOK: false))
        }
    }

    private func runExtract(query: String, topK: Int, threshold: Float) async {
        let outcome = await themesViewModel.extractTheme(
            parent: viewModel.cluster,
            queryText: query,
            topK: topK,
            similarityThreshold: threshold,
            relabel: true,
            dryRun: false
        )

        switch outcome {
        case .extracted(let newId, let count, let topScore):
            let scoreStr = String(format: "%.2f", topScore)
            alertState = .result(ResultAlert(
                title: "Extracted #\(newId) — \(count) Events",
                message: "Top similarity: \(scoreStr). Inspect the new tentative sub-theme under this cluster, then come back to Save Split or Discard Split.",
                dismissOnOK: false
            ))
        case .noMatches(let topScore):
            let scoreStr = String(format: "%.2f", topScore)
            alertState = .result(ResultAlert(
                title: "No Matches",
                message: "No events matched above the similarity threshold. Best match scored \(scoreStr). Try a lower threshold or rephrase the query.",
                dismissOnOK: false
            ))
        case .failed(let error):
            alertState = .result(ResultAlert(title: "Extract Failed", message: error, dismissOnOK: false))
        }
    }

    private func runSplit(minClusterSize: Int?, minSamples: Int?) async {
        let outcome = await themesViewModel.splitCluster(
            viewModel.cluster,
            minClusterSize: minClusterSize,
            minSamples: minSamples,
            relabel: true,
            dryRun: false
        )

        switch outcome {
        case .unchanged(let suggestion):
            alertState = .result(ResultAlert(title: "No Subdivision Found", message: suggestion, dismissOnOK: false))
        case .split(let newIds, let unfitted):
            let unfittedSuffix = unfitted > 0 ? " \(unfitted) event(s) didn't fit any sub-theme and remain in the parent." : ""
            alertState = .result(ResultAlert(
                title: "Split Created \(newIds.count) Tentative Sub-themes",
                message: "Inspect them in the themes list under this cluster, then come back to Save Split or Discard Split.\(unfittedSuffix)",
                dismissOnOK: false
            ))
        case .dryRun:
            // Dry-run is no longer surfaced from the UI; the menu always commits.
            break
        case .failed(let error):
            alertState = .result(ResultAlert(title: "Split Failed", message: error, dismissOnOK: false))
        }
    }

    // MARK: - Sections

    private var overviewSection: some View {
        Section {
            LabeledContent("Cluster ID") {
                Text("#\(viewModel.cluster.clusterId)")
                    .font(.body.monospaced())
                    .textSelection(.enabled)
            }

            if let parentId = liveCluster.parentClusterId {
                LabeledContent("Parent") {
                    Text("#\(parentId)")
                        .font(.body.monospaced())
                        .foregroundStyle(.secondary)
                }
            }

            if liveCluster.isTentative {
                Label("Tentative — part of an unsaved split", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }

            if let summary = viewModel.cluster.summary {
                Text(summary)
                    .textSelection(.enabled)
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

    @ViewBuilder
    private var tentativeChildrenSection: some View {
        let children = themesViewModel.subClusters(of: liveCluster.clusterId).filter(\.isTentative)
        if !children.isEmpty {
            Section {
                ForEach(children) { child in
                    NavigationLink(value: child) {
                        HStack {
                            Text("#\(child.clusterId)")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                            Text(child.label ?? "Untitled")
                                .italic()
                            Spacer()
                            Text("\(child.size)")
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(.secondary.opacity(0.15))
                                .clipShape(.capsule)
                        }
                    }
                }
            } header: {
                Label("Tentative Sub-themes (\(children.count))", systemImage: "tray.full")
            } footer: {
                Text("Use the Actions menu to Save or Discard this split.")
            }
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
