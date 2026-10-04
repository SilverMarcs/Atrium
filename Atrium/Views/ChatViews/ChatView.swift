import SwiftUI

struct ChatView: View {
    let chat: Chat

    @State private var isPreparingInitialScroll = true
    @State private var scrollAnchor = ScrollAnchor()
    @Environment(EditorPanel.self) private var panel

    private var session: AgentSession { chat.session }
    private var messages: [Message] { chat.messages }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(messages) { message in
                    MessageRow(message: message)
                        .listRowSeparator(.hidden)
                }

                if let error = session.error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .listRowSeparator(.hidden)
                        .frame(maxWidth: .infinity)
                        .foregroundStyle(.red)
                        .padding(.vertical)
                }

                Color.clear
                    .frame(height: 1)
                    .id("bottom")
                    .listRowSeparator(.hidden)
            }
            .bottomScrollAnchor(scrollAnchor, proxy: proxy)
            .toolbar {
                ToolbarItem(placement: .automatic) { ChatPermissionPicker(chat: chat) }
                ToolbarItem(placement: .automatic) { ChatModelPicker(chat: chat) }
                ToolbarSpacer(.fixed, placement: .automatic)
                ToolbarItem(placement: .automatic) { ChatReasoningPicker(chat: chat) }
            }
            .overlay {
                if isPreparingInitialScroll {
                    ZStack {
                        Rectangle()
                            .fill(.background)
                        ProgressView()
                            .controlSize(.large)
                    }
                } else if messages.isEmpty {
                    Image(chat.provider.imageName)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 100, height: 100)
                        .foregroundStyle(chat.provider.color.gradient)
                        .saturation(0)
                        .allowsHitTesting(false)
                }
            }
            .safeAreaBar(edge: .bottom) {
                VStack(spacing: 8) {
                    if let prompt = session.pendingPermission {
                        Divider()
                        PermissionPromptView(prompt: prompt)
                            .padding(.horizontal, 16)
                    }
                    if let request = session.pendingQuestion {
                        QuestionPromptView(prompt: request.prompt) { request.respond($0) }
                            .id(request.id)
                    }
                    if !chat.plan.isEmpty {
                        Divider()
                        PlanView(entries: chat.plan) {
                            chat.plan.removeAll()
                            session.plan.removeAll()
                        }
                        .padding(.horizontal, 16)
                    }
                    ChatInputArea(chat: chat)
                    .id(chat.id)
                }
            }
            .imageDropHandler(chat: chat)
            .environment(\.scrollAnchor, scrollAnchor)
            .onChange(of: messages.count) {
                guard !isPreparingInitialScroll else { return }
                scrollAnchor.scrollToBottom()
            }
            .task(id: chat.id) {
                chat.connectIfNeeded()
                isPreparingInitialScroll = true
                scrollAnchor.isEnabled = false
                try? await Task.sleep(for: .milliseconds(50))
                scrollAnchor.scrollToBottom(animated: false)
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { return }
                isPreparingInitialScroll = false
                scrollAnchor.isEnabled = true
            }
        }
    }
}
