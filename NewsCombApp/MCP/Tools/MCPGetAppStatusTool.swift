import Foundation
import MCP

/// Returns a snapshot of every long-running operation in the app — feed refresh,
/// knowledge graph processing, theme clustering — so MCP clients can poll progress
/// after firing off a background action.
enum MCPGetAppStatusTool {
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    static func run(arguments: [String: Value]) async -> String {
        let s = await MCPAppCoordinator.shared.snapshotStatus()

        var output = "## NewsComb App Status\n\n"

        // Feeds
        output += "### Feed Refresh\n"
        if s.isRefreshingFeeds {
            output += "- Status: **in progress** (\(s.feedsTotalItemsFetched) items fetched so far)\n"
        } else {
            output += "- Status: idle\n"
        }
        if let last = s.feedsLastRefresh {
            output += "- Last refresh: \(Self.dateFormatter.string(from: last))\n"
            output += "- New articles since last refresh: \(s.feedsNewArticles)\n"
        }

        // Knowledge graph
        output += "\n### Knowledge Graph Processing\n"
        if s.isProcessingHypergraph {
            output += "- Status: **in progress** — \(s.hypergraphStatus)\n"
            if s.hypergraphProgressTotal > 0 {
                output += "- Progress: \(s.hypergraphProgressProcessed)/\(s.hypergraphProgressTotal) articles\n"
            }
            if !s.currentProcessingArticle.isEmpty {
                output += "- Current article: \(s.currentProcessingArticle)\n"
            }
            if !s.recentlyExtractedEntities.isEmpty {
                output += "- Recently extracted: \(s.recentlyExtractedEntities.joined(separator: ", "))\n"
            }
        } else if s.isSimplifyingGraph {
            output += "- Status: **simplifying graph (auto-merge)**\n"
        } else if s.isResettingGraph {
            output += "- Status: **resetting graph**\n"
        } else {
            output += "- Status: idle\n"
        }
        if s.embeddingDimensionMismatch {
            output += "- ⚠️ Embedding model dimension mismatch — reset the graph before re-processing.\n"
        }

        // Themes
        output += "\n### Theme Clustering\n"
        if s.isRebuildingThemes {
            let pct = (s.themeRebuildProgress * 100).formatted(.number.precision(.fractionLength(0)))
            output += "- Status: **in progress** (\(pct)%) — \(s.themeRebuildStatus)\n"
        } else {
            output += "- Status: idle\n"
        }
        output += "- Themes: \(s.themeCount)\n"
        if s.themeTotalEvents > 0 {
            output += "- Clustered events: \(s.themeTotalEvents - s.themeNoiseCount), noise: \(s.themeNoiseCount)\n"
        }

        if let err = s.lastError {
            output += "\n### Last Error\n\(err)\n"
        }

        return output
    }
}
