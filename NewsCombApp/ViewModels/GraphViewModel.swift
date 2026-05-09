import Foundation
import Observation
import GRDB

/// ViewModel for the graph visualization view.
/// Manages graph data loading, layout computation, and interaction state.
@MainActor
@Observable
class GraphViewModel {

    // MARK: - Observable State

    /// All nodes in the graph
    var nodes: [GraphNode] = []

    /// All edges in the graph
    var edges: [GraphEdge] = []

    /// Loading state
    var isLoading = false

    /// Error message for display
    var errorMessage: String?

    /// Whether the layout simulation is running
    var isSimulating = false

    /// Currently selected edge ID for highlighting
    var selectedEdgeId: Int64?

    /// Currently hovered node ID for tooltip
    var hoveredNodeId: Int64?

    /// Currently hovered edge ID for tooltip
    var hoveredEdgeId: Int64?

    /// Connection threshold for filtering nodes (minimum degree to show).
    /// Changing the threshold clears any manually expanded nodes so the
    /// filter applies uniformly.
    var connectionThreshold: Int = 1 {
        didSet {
            if connectionThreshold != oldValue {
                expandedNodeIds.removeAll()
            showingMatchesOnly = false
            }
        }
    }

    /// Maximum degree across all nodes (for slider range)
    var maxDegree: Int = 1

    /// Nodes that have been manually expanded (shown despite being below threshold)
    var expandedNodeIds: Set<Int64> = []

    /// Custom node color hex value
    var nodeColorHex: String = AppSettings.defaultGraphNodeColor

    /// When true, `visibleNodes` is restricted to nodes that participate in
    /// the top-N longest paths instead of the connection-threshold filter.
    var showingLongestPathsOnly = false

    /// Set of node IDs that appear in the top longest paths (populated when
    /// `showingLongestPathsOnly` is enabled).
    var longestPathNodeIds: Set<Int64> = []

    /// When true, `visibleNodes` is restricted to search-matched nodes plus
    /// any node the user has expanded via double-click. Useful for drilling
    /// into a search result without surrounding clutter.
    var showingMatchesOnly = false

    /// How many longest paths to show when the filter is active.
    static let longestPathsCount = 10

    /// Cached top-N longest paths over the current graph. Invalidated when
    /// graph topology changes. Stored as `@ObservationIgnored` so reads
    /// during view rendering can populate it without observation churn.
    @ObservationIgnored
    private var cachedLongestPaths: [[Int64]]?

    /// Length (in nodes) of the single longest path in the current graph.
    /// Returns 0 if the graph has no edges or no path could be found.
    var longestPathLength: Int {
        longestPaths().first?.count ?? 0
    }

    /// Compute (or return cached) top-N longest paths over the current graph.
    func longestPaths() -> [[Int64]] {
        if let cached = cachedLongestPaths { return cached }

        let paths = LongestPathFinder.topLongestPaths(
            nodes: nodes,
            edges: edges,
            count: Self.longestPathsCount
        )
        cachedLongestPaths = paths
        return paths
    }

    /// Invalidate the longest-paths cache. Call after any topology change.
    private func invalidateLongestPathsCache() {
        cachedLongestPaths = nil
        // Reset the filter too: cached node IDs are stale.
        if showingLongestPathsOnly {
            showingLongestPathsOnly = false
            longestPathNodeIds = []
        }
    }

    // MARK: - Search State

    /// Current text in the search field.
    var searchText = ""

    /// Whether a search query is currently executing.
    var isSearching = false

    /// Results from the most recent search, if any.
    var searchResults: GraphSearchResults?

    /// Node IDs that matched the current search (directly or via chunks).
    var matchedNodeIds: Set<Int64> = []

    /// Whether the search results panel is visible.
    var showSearchResults = false

    @ObservationIgnored
    private var searchTask: Task<Void, Never>?

    // MARK: - Provenance State

    /// Node selected for provenance display
    var selectedNodeForProvenance: Int64?

    /// Edge selected for provenance display
    var selectedEdgeForProvenance: Int64?

    /// Provenance sources to display in the sheet
    var provenanceSources: [ProvenanceSource] = []

    /// Label of the selected item for provenance display
    var provenanceLabel: String = ""

    /// Whether provenance data is being loaded
    var isLoadingProvenance = false

    /// Whether to show the provenance sheet
    var showProvenanceSheet = false

    // MARK: - Private State

    @ObservationIgnored
    private let graphDataService = GraphDataService()

    @ObservationIgnored
    private let database = Database.current

    @ObservationIgnored
    private var layout = ForceDirectedLayout()

    @ObservationIgnored
    private var layoutTimer: Timer?

    @ObservationIgnored
    private var autoPauseTimer: Timer?

    @ObservationIgnored
    private var canvasSize: CGSize = CGSize(width: 1000, height: 800)

    /// The node ID that this graph is focused on (for neighborhood views).
    @ObservationIgnored
    private var focusedNodeId: Int64?

    /// Dictionary for O(1) node lookup by ID
    @ObservationIgnored
    private var nodeIndex: [Int64: Int] = [:]

    /// Frame counter for batched UI updates
    @ObservationIgnored
    private var frameCounter = 0

    /// Update SwiftUI state every N frames (reduces re-renders)
    private let uiUpdateInterval = 2

    /// Duration before auto-pause kicks in
    private let autoPauseDuration: TimeInterval = 3.0

    // MARK: - Computed Properties

    /// Nodes visible after applying the active filter mode.
    ///
    /// Three modes, mutually exclusive:
    /// - **Matches only** (`showingMatchesOnly`): search hits ∪ expanded.
    /// - **Longest paths** (`showingLongestPathsOnly`): nodes on the top-N
    ///   longest paths.
    /// - **Threshold** (default): degree ≥ threshold ∪ expanded.
    var visibleNodes: [GraphNode] {
        Self.filterVisibleNodes(
            nodes,
            showingMatchesOnly: showingMatchesOnly,
            showingLongestPathsOnly: showingLongestPathsOnly,
            matchedNodeIds: matchedNodeIds,
            expandedNodeIds: expandedNodeIds,
            longestPathNodeIds: longestPathNodeIds,
            connectionThreshold: connectionThreshold
        )
    }

    /// Pure filter logic, exposed for unit testing without instantiating the
    /// view model (which would touch `Database.current`).
    nonisolated static func filterVisibleNodes(
        _ nodes: [GraphNode],
        showingMatchesOnly: Bool,
        showingLongestPathsOnly: Bool,
        matchedNodeIds: Set<Int64>,
        expandedNodeIds: Set<Int64>,
        longestPathNodeIds: Set<Int64>,
        connectionThreshold: Int
    ) -> [GraphNode] {
        if showingMatchesOnly {
            return nodes.filter {
                matchedNodeIds.contains($0.id) || expandedNodeIds.contains($0.id)
            }
        }
        if showingLongestPathsOnly {
            return nodes.filter { longestPathNodeIds.contains($0.id) }
        }
        return nodes.filter {
            $0.degree >= connectionThreshold || expandedNodeIds.contains($0.id)
        }
    }

    /// Set of visible node IDs for efficient lookups
    var visibleNodeIds: Set<Int64> {
        Set(visibleNodes.map(\.id))
    }

    /// Edges where all endpoints are visible
    var visibleEdges: [GraphEdge] {
        let visible = visibleNodeIds
        return edges.filter { edge in
            edge.sourceNodeIds.allSatisfy { visible.contains($0) } &&
            edge.targetNodeIds.allSatisfy { visible.contains($0) }
        }
    }

    // MARK: - Initialization

    init() {
        loadNodeColorSetting()
    }

    // MARK: - Graph Loading

    /// Load the full knowledge graph from the database.
    func loadGraph() {
        isLoading = true
        errorMessage = nil
        invalidateLongestPathsCache()

        do {
            let data = try graphDataService.loadFullGraph()
            nodes = data.nodes
            edges = data.edges
            maxDegree = max(data.maxDegree, 1)
            expandedNodeIds.removeAll()
            showingMatchesOnly = false

            // Calculate optimal threshold to show ~50 nodes
            connectionThreshold = calculateOptimalThreshold(targetCount: 50)

            // Build node index for O(1) lookup
            rebuildNodeIndex()

            if !nodes.isEmpty {
                // Initialize layout with random positions
                layout.initialize(nodes: nodes, canvasSize: canvasSize)

                // Apply initial positions to nodes
                updateNodePositionsFromLayout()

                // Start the layout animation
                startLayoutAnimation()
            }
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    /// Calculate the minimum threshold that results in approximately targetCount visible nodes.
    private func calculateOptimalThreshold(targetCount: Int) -> Int {
        guard !nodes.isEmpty else { return 1 }

        // Sort degrees in descending order
        let sortedDegrees = nodes.map(\.degree).sorted(by: >)

        // If we have fewer nodes than target, show all
        if sortedDegrees.count <= targetCount {
            return 1
        }

        // Find the degree at the targetCount position
        // This will be our threshold (nodes with degree >= this will be shown)
        let thresholdDegree = sortedDegrees[targetCount - 1]

        // Return at least 1
        return max(thresholdDegree, 1)
    }

    /// Load a subgraph centered on a specific node.
    func loadNeighborhood(nodeId: Int64) {
        isLoading = true
        errorMessage = nil
        focusedNodeId = nodeId
        invalidateLongestPathsCache()

        do {
            let data = try graphDataService.loadNeighborhood(nodeId: nodeId)
            nodes = data.nodes
            edges = data.edges
            maxDegree = max(data.maxDegree, 1)
            expandedNodeIds.removeAll()
            showingMatchesOnly = false

            rebuildNodeIndex()

            if !nodes.isEmpty {
                // Use centered layout: pin the focused node at center, arrange neighbors in a circle
                layout.initializeWithCenter(nodes: nodes, centeredNodeId: nodeId, canvasSize: canvasSize)
                updateNodePositionsFromLayout()
                startLayoutAnimation()
            }
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    /// Reload the graph data.
    func reloadGraph() {
        stopLayoutAnimation()
        loadGraph()
    }

    // MARK: - Node Index

    /// Rebuild the node ID to index mapping for O(1) lookups.
    private func rebuildNodeIndex() {
        nodeIndex.removeAll(keepingCapacity: true)
        for (index, node) in nodes.enumerated() {
            nodeIndex[node.id] = index
        }
    }

    // MARK: - Layout Animation

    /// Start the physics simulation animation.
    func startLayoutAnimation() {
        guard layoutTimer == nil else { return }

        isSimulating = true
        layout.reset()
        frameCounter = 0

        // Run at 30 FPS instead of 60 for better performance with large graphs
        layoutTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.stepLayout()
            }
        }

        // Start auto-pause timer
        startAutoPauseTimer()
    }

    /// Start the auto-pause timer.
    private func startAutoPauseTimer() {
        autoPauseTimer?.invalidate()
        autoPauseTimer = Timer.scheduledTimer(withTimeInterval: autoPauseDuration, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.onAutoPause()
            }
        }
    }

    /// Called when auto-pause timer fires.
    private func onAutoPause() {
        stopLayoutAnimation()

        if let focusedNodeId {
            // In focused/neighborhood view: unpin the focused node and center on it
            layout.unpinNode(focusedNodeId)
            centerOnNode(focusedNodeId)
        } else {
            centerOnTopNodes()
        }
    }

    /// Stop the physics simulation animation.
    func stopLayoutAnimation() {
        layoutTimer?.invalidate()
        layoutTimer = nil
        autoPauseTimer?.invalidate()
        autoPauseTimer = nil
        isSimulating = false
    }

    /// Toggle layout simulation on/off.
    func toggleSimulation() {
        if isSimulating {
            stopLayoutAnimation()
        } else {
            startLayoutAnimation()
        }
    }

    /// Perform a single layout step.
    private func stepLayout() {
        guard isSimulating else { return }

        layout.step(edges: edges)
        frameCounter += 1

        // Only update SwiftUI state every N frames to reduce re-renders
        if frameCounter % uiUpdateInterval == 0 {
            updateNodePositionsFromLayout()
        }

        // Stop animation if layout has stabilized
        if layout.isStable {
            // Final position update
            updateNodePositionsFromLayout()
            stopLayoutAnimation()
        }
    }

    /// Update node positions from the layout engine.
    private func updateNodePositionsFromLayout() {
        for i in nodes.indices {
            if let position = layout.position(for: nodes[i].id) {
                nodes[i].position = position
            }
        }
    }

    // MARK: - Node Lookup

    /// Get a node by ID (O(1) lookup).
    func node(id: Int64) -> GraphNode? {
        guard let index = nodeIndex[id], index < nodes.count else { return nil }
        return nodes[index]
    }

    /// Get the index of a node by ID (O(1) lookup).
    func nodeIndexFor(id: Int64) -> Int? {
        nodeIndex[id]
    }

    /// Get an edge by ID.
    func edge(id: Int64) -> GraphEdge? {
        edges.first { $0.id == id }
    }

    // MARK: - Node Interaction

    /// Pin a node at a position (for dragging).
    func pinNode(_ nodeId: Int64) {
        guard let node = node(id: nodeId) else { return }
        layout.pinNode(nodeId, at: node.position)
    }

    /// Unpin a node to resume physics.
    /// Note: Does not restart layout - user can manually restart via Play button if needed.
    func unpinNode(_ nodeId: Int64) {
        layout.unpinNode(nodeId)
    }

    /// Move a node to a new position while dragging.
    func moveNode(_ nodeId: Int64, to position: CGPoint) {
        layout.moveNode(nodeId, to: position)

        // Update the node's position in our array using O(1) lookup
        if let index = nodeIndex[nodeId] {
            nodes[index].position = position
        }
    }

    // MARK: - Selection

    /// Toggle selection of an edge.
    func toggleEdgeSelection(_ edgeId: Int64) {
        if selectedEdgeId == edgeId {
            selectedEdgeId = nil
        } else {
            selectedEdgeId = edgeId
        }
    }

    /// Clear any selection.
    func clearSelection() {
        selectedEdgeId = nil
        hoveredNodeId = nil
    }

    // MARK: - Canvas Size

    /// Update the canvas size for layout calculations.
    func updateCanvasSize(_ size: CGSize) {
        canvasSize = size
    }

    /// Center the graph in the current canvas.
    /// In focused view, centers on the focused node. Otherwise, centers the bounding box.
    func centerGraph() {
        if let focusedNodeId {
            centerOnNode(focusedNodeId)
        } else {
            layout.centerGraph(in: canvasSize)
            updateNodePositionsFromLayout()
        }
    }

    // MARK: - Layout Parameters

    /// Adjust the spring length (ideal edge distance).
    func setSpringLength(_ length: CGFloat) {
        layout.springLength = length
        layout.reset()
        if !isSimulating {
            startLayoutAnimation()
        }
    }

    /// Adjust the repulsion strength.
    func setRepulsionStrength(_ strength: CGFloat) {
        layout.repulsionStrength = strength
        layout.reset()
        if !isSimulating {
            startLayoutAnimation()
        }
    }

    // MARK: - Centering on Top Nodes

    /// Center the view on a specific node.
    func centerOnNode(_ nodeId: Int64) {
        guard let node = node(id: nodeId) else { return }

        let offsetX = canvasSize.width / 2 - node.position.x
        let offsetY = canvasSize.height / 2 - node.position.y

        layout.applyOffset(dx: offsetX, dy: offsetY)
        updateNodePositionsFromLayout()
    }

    /// Center the view on the highest-connection nodes.
    func centerOnTopNodes(count: Int = 5) {
        // Get top N nodes by degree
        let topNodes = nodes
            .sorted { $0.degree > $1.degree }
            .prefix(count)

        guard !topNodes.isEmpty else { return }

        // Calculate center of top nodes
        var sumX: CGFloat = 0
        var sumY: CGFloat = 0
        for node in topNodes {
            sumX += node.position.x
            sumY += node.position.y
        }
        let centerX = sumX / CGFloat(topNodes.count)
        let centerY = sumY / CGFloat(topNodes.count)

        // Calculate offset to move this center to canvas center
        let canvasCenterX = canvasSize.width / 2
        let canvasCenterY = canvasSize.height / 2

        let offsetX = canvasCenterX - centerX
        let offsetY = canvasCenterY - centerY

        // Apply offset to layout
        layout.applyOffset(dx: offsetX, dy: offsetY)
        updateNodePositionsFromLayout()
    }

    // MARK: - Longest Paths Filter

    /// Toggle the "show only top-N longest paths" filter.
    ///
    /// When enabling, computes the longest paths over the currently loaded
    /// graph and stores the union of nodes that participate in them.
    /// When disabling, clears the cached node set so the regular threshold
    /// filter takes over again.
    func toggleLongestPaths() {
        if showingLongestPathsOnly {
            showingLongestPathsOnly = false
            longestPathNodeIds = []
            return
        }

        let paths = longestPaths()
        let pathNodeIds = Set(paths.flatMap { $0 })

        guard !pathNodeIds.isEmpty else {
            errorMessage = "Could not find any paths in the current graph."
            return
        }

        // Mutually exclusive with the matches-only filter.
        showingMatchesOnly = false
        longestPathNodeIds = pathNodeIds
        showingLongestPathsOnly = true
    }

    // MARK: - Focus on Search Match

    /// Bring a search-result node into the visible graph and switch to the
    /// matches-only filter so the user sees a small, connected island
    /// centered on what they just clicked — not every search hit at once.
    ///
    /// Steps:
    /// 1. Narrow `matchedNodeIds` to just this row, so only the clicked
    ///    node is drawn yellow (the rest of the FTS hits stop dominating
    ///    the canvas).
    /// 2. Expand the node (loads its 1-hop neighbors into `expandedNodeIds`,
    ///    which `filterVisibleNodes` unions with `matchedNodeIds`).
    /// 3. Activate `showingMatchesOnly` (mutually exclusive with longest paths).
    /// 4. Center the view on the matched node.
    ///
    /// The full `searchResults` panel data is preserved so the user can
    /// click another row to pivot focus.
    ///
    /// `expandNode` is a no-op when the node isn't currently in `nodes`
    /// (e.g., focused-view searches that match outside the loaded
    /// neighborhood). The matched node itself stays visible through
    /// `matchedNodeIds` regardless.
    func focusOnSearchMatch(nodeId: Int64) {
        matchedNodeIds = [nodeId]
        expandNode(nodeId)

        if showingLongestPathsOnly {
            showingLongestPathsOnly = false
            longestPathNodeIds = []
        }
        showingMatchesOnly = true

        centerOnNode(nodeId)
    }

    // MARK: - Matches-Only Filter

    /// Toggle the "show only search matches and expanded neighbors" filter.
    ///
    /// When enabled, `visibleNodes` is restricted to the union of
    /// `matchedNodeIds` (search hits, drawn yellow) and `expandedNodeIds`
    /// (nodes the user has revealed via double-click). Designed for the flow:
    /// *search → see the yellow matches → double-click one to expand its
    /// neighbors → keep drilling without other clutter on screen.*
    func toggleMatchesOnly() {
        if showingMatchesOnly {
            showingMatchesOnly = false
            return
        }

        guard !matchedNodeIds.isEmpty || !expandedNodeIds.isEmpty else {
            errorMessage = "No search matches yet. Search for a node or edge first, then enable this filter."
            return
        }

        // Mutually exclusive with the longest-paths filter.
        if showingLongestPathsOnly {
            showingLongestPathsOnly = false
            longestPathNodeIds = []
        }
        showingMatchesOnly = true
    }

    // MARK: - Node Color Settings

    /// Load the node color setting from the database.
    private func loadNodeColorSetting() {
        do {
            if let setting = try database.read({ db in
                try AppSettings.filter(AppSettings.Columns.key == AppSettings.graphNodeColor).fetchOne(db)
            }) {
                nodeColorHex = setting.value
            }
        } catch {
            nodeColorHex = AppSettings.defaultGraphNodeColor
        }
    }

    /// Save the node color to the database.
    func saveNodeColor(_ hex: String) {
        nodeColorHex = hex
        do {
            try database.write { db in
                try db.execute(sql: """
                    INSERT INTO app_settings (key, value) VALUES (?, ?)
                    ON CONFLICT(key) DO UPDATE SET value = excluded.value
                """, arguments: [AppSettings.graphNodeColor, hex])
            }
        } catch {
            // Silently fail - color will reset on next load
        }
    }

    // MARK: - Node Expansion

    /// Expand a node to show its hidden neighbors.
    ///
    /// Handles two cases transparently:
    /// - **Full graph**: Neighbors are already in `nodes` but hidden by the
    ///   connection threshold — they're added to `expandedNodeIds` so the
    ///   visibility filter includes them.
    /// - **Focused view**: Neighbors aren't loaded at all — their data is
    ///   fetched from the database, appended to `nodes` and `edges`, and
    ///   registered with the layout engine.
    func expandNode(_ nodeId: Int64) {
        guard node(id: nodeId) != nil else { return }

        do {
            // Load the full 1-hop neighborhood of the expanded node
            let neighborhoodData = try graphDataService.loadNeighborhood(nodeId: nodeId)

            let existingIds = Set(nodes.map(\.id))
            var revealedIds: [Int64] = []
            var addedNodes: [GraphNode] = []

            for neighbor in neighborhoodData.nodes {
                guard neighbor.id != nodeId else { continue }
                guard !expandedNodeIds.contains(neighbor.id) else { continue }

                if existingIds.contains(neighbor.id) {
                    // Node is loaded but may be hidden by threshold
                    if let existingNode = self.node(id: neighbor.id),
                       existingNode.degree < connectionThreshold {
                        expandedNodeIds.insert(neighbor.id)
                        revealedIds.append(neighbor.id)
                    }
                } else {
                    // Node isn't loaded — add it to the graph
                    addedNodes.append(neighbor)
                    expandedNodeIds.insert(neighbor.id)
                }
            }

            // Merge new data into the graph
            if !addedNodes.isEmpty {
                invalidateLongestPathsCache()
                nodes.append(contentsOf: addedNodes)

                let existingEdgeIds = Set(edges.map(\.id))
                let newEdges = neighborhoodData.edges.filter { !existingEdgeIds.contains($0.id) }
                edges.append(contentsOf: newEdges)

                recomputeDegrees()
                maxDegree = max(nodes.map(\.degree).max() ?? 1, 1)
                rebuildNodeIndex()

                // Register new nodes with the layout engine near the parent
                if let parentPos = layout.position(for: nodeId) {
                    layout.addNodes(addedNodes.map(\.id), near: parentPos)
                }
                updateNodePositionsFromLayout()
            }

            let allNewIds = revealedIds + addedNodes.map(\.id)
            guard !allNewIds.isEmpty else { return }

            // Run partial layout to settle the new nodes
            startPartialLayout(pinExcept: allNewIds, duration: 1.0)

        } catch {
            // Silently fail - expansion won't work
        }
    }

    /// Recompute node degrees from the current set of edges.
    private func recomputeDegrees() {
        var degreeMap: [Int64: Int] = [:]
        for edge in edges {
            for nodeId in edge.sourceNodeIds + edge.targetNodeIds {
                degreeMap[nodeId, default: 0] += 1
            }
        }
        for i in nodes.indices {
            nodes[i].degree = degreeMap[nodes[i].id] ?? 0
        }
    }

    /// Start a partial layout that only moves certain nodes.
    private func startPartialLayout(pinExcept nodeIds: [Int64], duration: TimeInterval) {
        // Pin all nodes except the new ones
        for node in nodes {
            if !nodeIds.contains(node.id) {
                layout.pinNode(node.id, at: node.position)
            }
        }

        // Start simulation
        startLayoutAnimation()

        // Schedule stop after duration
        Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.stopLayoutAnimation()
                // Unpin all nodes
                for node in self?.nodes ?? [] {
                    self?.layout.unpinNode(node.id)
                }
            }
        }
    }

    // MARK: - Provenance Loading

    /// Load provenance for a node and show the provenance sheet.
    func loadNodeProvenance(nodeId: Int64) {
        selectedNodeForProvenance = nodeId
        selectedEdgeForProvenance = nil
        isLoadingProvenance = true

        do {
            provenanceSources = try graphDataService.loadProvenanceForNode(nodeId: nodeId)
            provenanceLabel = try graphDataService.loadNodeLabel(nodeId: nodeId) ?? "Unknown"
            showProvenanceSheet = true
        } catch {
            provenanceSources = []
            provenanceLabel = ""
        }

        isLoadingProvenance = false
    }

    /// Load provenance for an edge and show the provenance sheet.
    func loadEdgeProvenance(edgeId: Int64) {
        selectedEdgeForProvenance = edgeId
        selectedNodeForProvenance = nil
        isLoadingProvenance = true

        do {
            provenanceSources = try graphDataService.loadProvenanceForEdge(edgeId: edgeId)
            provenanceLabel = try graphDataService.loadEdgeLabel(edgeId: edgeId) ?? "Unknown"
            showProvenanceSheet = true
        } catch {
            provenanceSources = []
            provenanceLabel = ""
        }

        isLoadingProvenance = false
    }

    /// Clear provenance selection state.
    func clearProvenanceSelection() {
        selectedNodeForProvenance = nil
        selectedEdgeForProvenance = nil
        provenanceSources = []
        provenanceLabel = ""
        showProvenanceSheet = false
    }

    // MARK: - Full-Text Search

    /// Debounce and execute a search.
    /// Cancels any in-flight search and waits 300ms before executing.
    func performSearch() {
        searchTask?.cancel()

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !query.isEmpty else {
            clearSearch()
            return
        }

        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await executeSearch(query: query)
        }
    }

    /// Execute the FTS5 search and update results state.
    private func executeSearch(query: String) async {
        isSearching = true
        do {
            let results = try graphDataService.searchAll(query: query)
            searchResults = results
            matchedNodeIds = results.allMatchedNodeIds
            showSearchResults = !results.isEmpty
        } catch {
            searchResults = nil
            matchedNodeIds = []
            showSearchResults = false
        }
        isSearching = false
    }

    /// Clear all search state.
    func clearSearch() {
        searchTask?.cancel()
        searchText = ""
        isSearching = false
        searchResults = nil
        matchedNodeIds = []
        showSearchResults = false
    }
}
