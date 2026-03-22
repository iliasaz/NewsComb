import SwiftUI

/// Chat interface for interviewing a social agent.
struct AgentInterviewView: View {
    @State private var viewModel: AgentInterviewViewModel

    init(agent: SocialAgent) {
        _viewModel = State(initialValue: AgentInterviewViewModel(agent: agent))
    }

    var body: some View {
        VStack(spacing: 0) {
            messageList
            inputBar
        }
        .navigationTitle("Interview: \(viewModel.agent.displayName)")
        .onDisappear {
            viewModel.saveConversation()
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

    // MARK: - Message List

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(viewModel.messages.indices, id: \.self) { index in
                        MessageBubble(message: viewModel.messages[index])
                            .id(index)
                    }

                    // Streaming response
                    if viewModel.isResponding && !viewModel.streamingResponse.isEmpty {
                        MessageBubble(message: AgentInterview.Message(
                            role: "assistant",
                            content: viewModel.streamingResponse,
                            timestamp: Date()
                        ))
                        .id("streaming")
                    }

                    if viewModel.isResponding && viewModel.streamingResponse.isEmpty {
                        HStack {
                            ProgressView()
                                .controlSize(.small)
                            Text("\(viewModel.agent.displayName) is thinking\u{2026}")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal)
                        .id("loading")
                    }
                }
                .padding()
            }
            .scrollIndicators(.hidden)
            .onChange(of: viewModel.messages.count) {
                withAnimation {
                    proxy.scrollTo(viewModel.messages.count - 1, anchor: .bottom)
                }
            }
            .onChange(of: viewModel.streamingResponse) {
                withAnimation {
                    proxy.scrollTo("streaming", anchor: .bottom)
                }
            }
        }
    }

    // MARK: - Input Bar

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("Ask \(viewModel.agent.displayName) a question\u{2026}", text: $viewModel.inputText)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    Task { await viewModel.sendMessage() }
                }
                .disabled(viewModel.isResponding)

            Button("Send", systemImage: "arrow.up.circle.fill") {
                Task { await viewModel.sendMessage() }
            }
            .disabled(viewModel.inputText.trimmingCharacters(in: .whitespaces).isEmpty || viewModel.isResponding)
        }
        .padding()
        .background(.bar)
    }
}

// MARK: - Message Bubble

private struct MessageBubble: View {
    let message: AgentInterview.Message

    var body: some View {
        HStack {
            if message.role == "user" { Spacer(minLength: 60) }

            VStack(alignment: message.role == "user" ? .trailing : .leading, spacing: 4) {
                Text(message.content)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(message.role == "user" ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.15))
                    .clipShape(.rect(cornerRadius: 12))
            }

            if message.role != "user" { Spacer(minLength: 60) }
        }
    }
}
