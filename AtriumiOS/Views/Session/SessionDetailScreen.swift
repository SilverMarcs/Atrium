import SwiftUI

struct SessionDetailScreen: View {
    @Environment(CompanionClient.self) private var client
    let sessionId: UUID

    @State private var draft: String = ""
    @State private var showingInspector = false
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if let session = client.activeSession {
                            ForEach(session.messages) { message in
                                MessageBubble(message: message)
                                    .id(message.id)
                            }
                            if session.meta.isProcessing {
                                ThinkingIndicator()
                            }
                        } else {
                            HStack { Spacer(); ProgressView(); Spacer() }
                                .padding(.top, 60)
                        }
                    }
                    .padding()
                }
                .onChange(of: client.activeSession?.messages.last?.id) { _, newId in
                    if let id = newId {
                        withAnimation { proxy.scrollTo(id, anchor: .bottom) }
                    }
                }
            }

            Divider()

            ComposeBar(draft: $draft, inputFocused: $inputFocused) {
                let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return }
                client.sendPrompt(text)
                draft = ""
                inputFocused = false
            }
        }
        .navigationTitle(client.activeSession?.meta.title ?? "Session")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingInspector = true
                } label: {
                    Label("Info", systemImage: "info")
                }
                .disabled(client.activeSession == nil)
            }
        }
        .sheet(isPresented: $showingInspector) {
            if let workspaceId = client.activeSession?.meta.workspaceId {
                SessionInspectorSheet(workspaceId: workspaceId)
            }
        }
        .task(id: sessionId) {
            client.subscribe(to: sessionId)
        }
        .onDisappear { client.unsubscribe() }
    }
}
