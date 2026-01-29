import SwiftUI

/// Enhanced reasoning path display showing nodes as colored pills with relation labels between them.
/// Uses Apple Design-style subtle text labels with arrows.
struct EnhancedReasoningPathRow: View {
    let path: GraphRAGResponse.ReasoningPath

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Path description with hop count
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: path.isMultiHop ? "arrow.triangle.2.circlepath" : "arrow.right")
                    .foregroundStyle(path.isMultiHop ? .purple : .secondary)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 4) {
                    Text(path.description)
                        .font(.subheadline)

                    Text("\(path.edgeCount) hop\(path.edgeCount == 1 ? "" : "s")")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(path.isMultiHop ? Color.purple.opacity(0.15) : Color.secondary.opacity(0.15))
                        .foregroundStyle(path.isMultiHop ? .purple : .secondary)
                        .clipShape(.capsule)
                }
            }

            // Visual path representation with relation labels
            if path.edgeCount > 0 {
                pathVisualization
                    .padding(.leading, 24)
            }
        }
        .padding(.vertical, 4)
    }

    /// Visual representation of the path with nodes and relation labels.
    private var pathVisualization: some View {
        FlowLayout(spacing: 4) {
            // Source node
            conceptPill(path.sourceConcept, color: .blue)

            // Intermediate nodes with relations
            ForEach(path.intermediateNodes.enumerated().map { PathNode(index: $0.offset, label: $0.element) }) { pathNode in
                relationArrow(labelAt: pathNode.index)
                conceptPill(pathNode.label, color: .orange)
            }

            // Final relation and target
            relationArrow(labelAt: path.intermediateNodes.count)
            conceptPill(path.targetConcept, color: .green)
        }
    }

    /// Helper struct for ForEach iteration over enumerated nodes.
    private struct PathNode: Identifiable {
        let index: Int
        let label: String
        var id: String { "\(index)-\(label)" }
    }

    /// Creates a concept pill with the given label and color.
    private func conceptPill(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(.capsule)
    }

    /// Creates a relation label with arrow, styled as a bordered indigo pill.
    private func relationArrow(labelAt index: Int) -> some View {
        HStack(spacing: 2) {
            if index < path.edgeLabels.count {
                Text(formatRelation(path.edgeLabels[index]))
                    .font(.caption2)
                    .foregroundStyle(.indigo)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.indigo.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(.indigo.opacity(0.4), lineWidth: 1)
                    )
                    .clipShape(.rect(cornerRadius: 4))
            }
            Image(systemName: "arrow.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    /// Formats a relation string to be human-readable.
    private func formatRelation(_ relation: String) -> String {
        // Remove leading numeric prefixes (like "0_" or "chunk_0_")
        var cleaned = relation

        let prefixPatterns = [#"^\d+_"#, #"^chunk_\d+_"#, #"^rel_\d+_"#]
        for pattern in prefixPatterns {
            if let regex = try? Regex(pattern) {
                cleaned = cleaned.replacing(regex, with: "")
            }
        }

        // Also remove trailing chunk references like "_chunk_0"
        if let suffixRegex = try? Regex(#"_chunk_\d+$"#) {
            cleaned = cleaned.replacing(suffixRegex, with: "")
        }

        // Replace underscores with spaces
        return cleaned.replacing("_", with: " ")
    }
}

/// A simple flow layout for wrapping views.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    struct LayoutResult {
        let size: CGSize
        let placements: [Placement]
    }

    struct Placement {
        let origin: CGPoint
        let size: CGSize
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = layout(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(proposal: proposal, subviews: subviews)

        for (index, placement) in result.placements.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + placement.origin.x, y: bounds.minY + placement.origin.y),
                proposal: ProposedViewSize(placement.size)
            )
        }
    }

    private func layout(proposal: ProposedViewSize, subviews: Subviews) -> LayoutResult {
        let maxWidth = proposal.width ?? .infinity
        var placements: [Placement] = []

        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0
        var totalHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)

            if currentX + size.width > maxWidth && currentX > 0 {
                currentX = 0
                currentY += lineHeight + spacing
                lineHeight = 0
            }

            placements.append(Placement(origin: CGPoint(x: currentX, y: currentY), size: size))
            currentX += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            totalHeight = currentY + lineHeight
        }

        return LayoutResult(size: CGSize(width: maxWidth, height: totalHeight), placements: placements)
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 16) {
        // Single-hop path
        EnhancedReasoningPathRow(path: GraphRAGResponse.ReasoningPath(
            sourceConcept: "Apple",
            targetConcept: "Tim Cook",
            intermediateNodes: [],
            edgeCount: 1,
            edgeLabels: ["led by"]
        ))

        Divider()

        // Multi-hop path
        EnhancedReasoningPathRow(path: GraphRAGResponse.ReasoningPath(
            sourceConcept: "Palo Alto Networks",
            targetConcept: "BigQuery",
            intermediateNodes: ["Google Cloud", "Dataflow"],
            edgeCount: 3,
            edgeLabels: ["partnered with", "provides", "integrates with"]
        ))

        Divider()

        // Another multi-hop path
        EnhancedReasoningPathRow(path: GraphRAGResponse.ReasoningPath(
            sourceConcept: "ServiceNow",
            targetConcept: "AI",
            intermediateNodes: ["OpenAI"],
            edgeCount: 2,
            edgeLabels: ["partnered with", "develops"]
        ))
    }
    .padding()
}
