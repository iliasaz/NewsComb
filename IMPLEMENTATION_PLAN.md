# Implementation Plan: "Dive Deeper" Agentic Workflow (Issue #3)

## Overview

Add a "Dive Deeper" feature to the Answer view that triggers a multi-step agentic analysis workflow, generating hypotheses and deeper insights based on the initial GraphRAG response.

## Architecture Decision

**Chosen Approach: Option A - Sequential LLM Calls (Simulated Agents)**

Rather than introducing a full agent framework dependency (like SwiftAgents), we'll implement the multi-agent pattern using sequential LLM calls with specialized prompts. This approach:
- Keeps the codebase simple and dependency-light
- Matches the Python reference implementation's core behavior
- Is easier to debug and maintain
- Follows the existing `GraphRAGService` patterns

## Agent Workflow

Based on the Python reference implementation (`Agents.ipynb`), the workflow is:

```
User Question + Initial Answer
       ↓
[Engineer Agent] - Synthesizes answer with academic citations [1], [2]
       ↓
[Hypothesizer Agent] - Suggests experiments/hypotheses based on connections
       ↓
Deep Analysis Result
```

Note: The GraphRAG retrieval step is already done in the initial query, so "Dive Deeper" starts from the Engineer stage.

## Implementation Steps

### Phase 1: Data Model Extensions

**File: `NewsCombApp/Models/GraphRAGResponse.swift`**

Add a new structure to hold deep analysis results:

```swift
/// Result of the "Dive Deeper" agentic analysis workflow.
struct DeepAnalysisResult: Codable, Equatable, Hashable {
    /// The synthesized answer with academic-style citations.
    let synthesizedAnswer: String

    /// Hypotheses and experiment suggestions based on the knowledge graph connections.
    let hypotheses: String

    /// Timestamp when the analysis was performed.
    let timestamp: Date
}
```

Extend `GraphRAGResponse` to optionally include deep analysis:

```swift
extension GraphRAGResponse {
    /// Deep analysis result from "Dive Deeper" workflow (optional).
    var deepAnalysis: DeepAnalysisResult? // Will need storage strategy
}
```

### Phase 2: Deep Analysis Service

**New File: `NewsCombApp/Services/DeepAnalysisService.swift`**

Create a service that orchestrates the multi-agent workflow:

```swift
final class DeepAnalysisService: Sendable {

    /// Performs deep analysis on an existing GraphRAG response.
    /// - Parameters:
    ///   - question: The original user question
    ///   - initialAnswer: The initial GraphRAG answer
    ///   - context: The gathered context (nodes, edges, chunks)
    /// - Returns: A DeepAnalysisResult with synthesized answer and hypotheses
    @MainActor
    func analyze(
        question: String,
        initialAnswer: String,
        relatedNodes: [GraphRAGResponse.RelatedNode],
        reasoningPaths: [GraphRAGResponse.ReasoningPath],
        graphPaths: [GraphRAGResponse.GraphPath]
    ) async throws -> DeepAnalysisResult
}
```

**Agent Prompts:**

1. **Engineer Agent Prompt** (synthesize with citations):
```
You are a research engineer with scientific backgrounds.
Based on the knowledge graph relationships provided, synthesize an answer to the question.

Rules:
- Use academic citation style: '<statement> [1]'
- Include a References section: [1] <REFERENCE>: <reasoning>
- Only cite information from the provided relationships
- Mark hypothetical ideas clearly as such
- Do not fabricate references

Question: {question}
Initial Analysis: {initialAnswer}
Knowledge Graph Relationships:
{formattedPaths}
```

2. **Hypothesizer Agent Prompt** (generate hypotheses):
```
You are a creative hypothesizer agent.
Based on the synthesized analysis and knowledge graph connections, suggest:
1. Plausible experiments or investigations that could reveal new insights
2. Potential connections or patterns not explicitly stated
3. Questions that would be worth exploring further

Be creative but grounded in the provided information.

Synthesized Analysis:
{engineerAnswer}

Original Question: {question}
```

### Phase 3: View Model Updates

**File: `NewsCombApp/ViewModels/AnswerDetailViewModel.swift`** (new file)

Create a dedicated view model for the answer detail view:

```swift
@MainActor
@Observable
class AnswerDetailViewModel {
    let response: GraphRAGResponse
    let historyItem: QueryHistoryItem

    private(set) var deepAnalysisResult: DeepAnalysisResult?
    private(set) var isAnalyzing = false
    private(set) var analysisError: String?

    private let deepAnalysisService = DeepAnalysisService()

    func performDeepAnalysis() async {
        isAnalyzing = true
        analysisError = nil

        do {
            deepAnalysisResult = try await deepAnalysisService.analyze(
                question: response.query,
                initialAnswer: response.answer,
                relatedNodes: response.relatedNodes,
                reasoningPaths: response.reasoningPaths,
                graphPaths: response.graphPaths
            )
            // Persist to database
            try saveDeepAnalysis()
        } catch {
            analysisError = error.localizedDescription
        }

        isAnalyzing = false
    }

    private func saveDeepAnalysis() throws {
        // Update QueryHistoryItem with deep analysis result
    }
}
```

### Phase 4: UI Updates

**File: `NewsCombApp/Views/AnswerDetailView.swift`**

Add a new "Deep Analysis" section after the existing sections:

```swift
private var deepAnalysisSection: some View {
    Section {
        if viewModel.isAnalyzing {
            HStack {
                ProgressView()
                    .controlSize(.small)
                Text("Analyzing...")
                    .foregroundStyle(.secondary)
            }
        } else if let result = viewModel.deepAnalysisResult {
            // Display synthesized answer with citations
            VStack(alignment: .leading, spacing: 12) {
                Text("Synthesized Analysis")
                    .font(.headline)
                Text(result.synthesizedAnswer)
                    .textSelection(.enabled)

                Divider()

                Text("Hypotheses & Experiments")
                    .font(.headline)
                Text(result.hypotheses)
                    .textSelection(.enabled)
            }
        } else {
            Button("Dive Deeper") {
                Task {
                    await viewModel.performDeepAnalysis()
                }
            }
            .buttonStyle(.borderedProminent)
        }

        if let error = viewModel.analysisError {
            Text(error)
                .foregroundStyle(.red)
                .font(.caption)
        }
    } header: {
        Text("Deep Analysis")
    } footer: {
        Text("Use AI agents to synthesize insights with citations and generate hypotheses based on knowledge graph connections.")
    }
}
```

### Phase 5: Persistence

**File: `NewsCombApp/Models/QueryHistoryItem.swift`**

Extend to store deep analysis results:

```swift
extension QueryHistoryItem {
    // Add column for deep analysis JSON
    static let deepAnalysisJSON = "deep_analysis_json"

    var deepAnalysis: DeepAnalysisResult? {
        get { /* decode from JSON */ }
        set { /* encode to JSON */ }
    }
}
```

**Database Migration:**

Add migration to include the new column:

```sql
ALTER TABLE query_history ADD COLUMN deep_analysis_json TEXT;
```

## File Changes Summary

| File | Change Type | Description |
|------|-------------|-------------|
| `Models/GraphRAGResponse.swift` | Modify | Add `DeepAnalysisResult` struct |
| `Services/DeepAnalysisService.swift` | New | Multi-agent orchestration service |
| `ViewModels/AnswerDetailViewModel.swift` | New | View model for answer detail |
| `Views/AnswerDetailView.swift` | Modify | Add deep analysis section and button |
| `Models/QueryHistoryItem.swift` | Modify | Add deep analysis persistence |
| `Database/Database.swift` | Modify | Add migration for new column |

## Testing Plan

1. **Unit Tests for DeepAnalysisService:**
   - Test prompt formatting
   - Test response parsing
   - Test error handling when LLM fails

2. **Integration Tests:**
   - Test full workflow from button press to result display
   - Test persistence and retrieval of deep analysis

3. **Manual Testing:**
   - Verify UI states (loading, success, error)
   - Verify citation formatting in output
   - Test with various query types

## Commit Strategy

1. **Commit 1**: Add `DeepAnalysisResult` model and database migration
2. **Commit 2**: Implement `DeepAnalysisService` with agent prompts
3. **Commit 3**: Add `AnswerDetailViewModel` with analysis logic
4. **Commit 4**: Update `AnswerDetailView` with UI for deep analysis
5. **Commit 5**: Add persistence to `QueryHistoryItem`
6. **Commit 6**: Add tests and documentation

## Dependencies

No new external dependencies required. Uses existing:
- `OllamaService` / `OpenRouterService` for LLM calls
- `GRDB` for persistence
- SwiftUI for UI
