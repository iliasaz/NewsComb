import Foundation

/// Navigation value for a live (in-progress) query.
///
/// Used for programmatic navigation to `AnswerDetailView` immediately
/// after the user submits a question, before the pipeline completes.
/// The private `id` ensures uniqueness even for repeated queries.
struct LiveQueryNavigation: Hashable {
    let query: String
    let rolePrompt: String?
    private let id = UUID()
}
