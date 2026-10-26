import SwiftUI

/// A task's conversation, scrolled to the latest message, with the agent's state below it.
struct TaskChatView: View {
    @Environment(CompanionClient.self) private var client
    let task: WireTask

    private static let bottomID = "bottom"

    private var messages: [TranscriptMessage]? { client.transcripts[task.id] }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(messages ?? []) { message in
                        switch message.role {
                        case .user:
                            UserMessageView(text: message.blocks.filter { $0.kind == .text }.map(\.text).joined(separator: "\n"))
                        case .assistant:
                            AssistantMessageView(
                                blocks: message.blocks,
                                isStreaming: task.status == .processing && message.id == messages?.last?.id
                            )
                        }
                    }
                    TaskChatStatusFooter(status: task.status)
                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomID)
                }
            }
            .contentMargins(.top, 10, for: .scrollContent)
            .contentMargins([.horizontal, .bottom], 20, for: .scrollContent)
            .scrollDismissesKeyboard(.interactively)
            .defaultScrollAnchor(.bottom)
            .onChange(of: messages?.last) {
                withAnimation { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
            }
            .overlay {
                if messages == nil {
                    ProgressView()
                        .controlSize(.large)
                } else if messages?.isEmpty == true {
                    ContentUnavailableView("No Messages Yet", systemImage: "bubble.left", description: Text("Send a prompt to start."))
                }
            }
        }
    }
}
