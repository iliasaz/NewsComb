import Foundation
import Observation
import OSLog

/// View model for the agent interview chat interface.
@MainActor
@Observable
final class AgentInterviewViewModel {

    // MARK: - State

    let agent: SocialAgent
    private(set) var messages: [AgentInterview.Message] = []
    var inputText = ""
    private(set) var isResponding = false
    private(set) var streamingResponse = ""
    var errorMessage: String?

    // MARK: - Internal

    private let interviewService = AgentInterviewService()
    private let logger = Logger(subsystem: "com.newscomb", category: "AgentInterviewViewModel")

    init(agent: SocialAgent) {
        self.agent = agent
    }

    // MARK: - Actions

    func sendMessage() async {
        let prompt = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isResponding else { return }

        inputText = ""
        isResponding = true
        streamingResponse = ""

        // Add user message
        messages.append(AgentInterview.Message(
            role: "user",
            content: prompt,
            timestamp: Date()
        ))

        do {
            let response = try await interviewService.interview(
                agent: agent,
                prompt: prompt,
                conversationHistory: messages,
                tokenCallback: { [weak self] token in
                    self?.streamingResponse += token
                }
            )

            // Use streamed response if available, otherwise use full response
            let finalResponse = streamingResponse.isEmpty ? response : streamingResponse

            messages.append(AgentInterview.Message(
                role: "assistant",
                content: finalResponse,
                timestamp: Date()
            ))

            streamingResponse = ""
        } catch {
            logger.error("Interview failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = error.localizedDescription
        }

        isResponding = false
    }

    /// Saves the current conversation to the database.
    func saveConversation() {
        guard let agentId = agent.id, !messages.isEmpty else { return }
        do {
            try interviewService.saveConversation(
                agentId: agentId,
                messages: messages,
                simulationId: agent.simulationId
            )
        } catch {
            logger.error("Failed to save conversation: \(error.localizedDescription, privacy: .public)")
        }
    }
}
