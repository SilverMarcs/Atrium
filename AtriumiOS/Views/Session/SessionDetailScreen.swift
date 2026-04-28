import SwiftUI

/// Mirrors LynkChat's `ChatDetailMobile` shape: scrolling conversation,
/// searchable-driven bottom-bar input, info button up top, stop button on
/// the bottom bar while the host is processing. No assistant-side label —
/// just user bubbles vs. left-aligned assistant content.
struct SessionDetailScreen: View {
    @Environment(CompanionClient.self) private var client
    let sessionId: UUID

    @State private var draft: String = ""
    @State private var isInputFocused: Bool = false
    @State private var showingInspector = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if let session = client.activeSession {
                        ForEach(session.messages) { message in
                            messageView(for: message)
                                .id(message.id)
                                .padding(.vertical, 2)
                        }
                        if session.meta.isProcessing {
                            ProgressView()
                                .controlSize(.small)
                                .padding(.top, 4)
                        }
                    } else {
                        HStack { Spacer(); ProgressView(); Spacer() }
                            .padding(.top, 60)
                    }
                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomID)
                }
            }
            .contentMargins(.top, 10)
            .contentMargins([.horizontal, .bottom], 15)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: client.activeSession?.messages.last?.id) { _, _ in
                // withAnimation {
                     proxy.scrollTo(Self.bottomID, anchor: .bottom) 
                // }
            }
            .onChange(of: isInputFocused) { _, focused in
                if focused {
                    Task {
                        try? await Task.sleep(for: .milliseconds(200))
                        proxy.scrollTo(Self.bottomID, anchor: .bottom)
                    }
                }
            }
        }
        .navigationTitle(client.activeSession?.meta.title ?? "Session")
        .toolbarTitleDisplayMode(.inline)
        .searchable(
            text: $draft,
            isPresented: $isInputFocused,
            prompt: "Ask anything…"
        )
        .searchPresentationToolbarBehavior(.avoidHidingContent)
        .onSubmit(of: .search) { sendDraft() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingInspector = true
                } label: {
                    Label("Info", systemImage: "info")
                }
                .disabled(client.activeSession == nil)
            }
            DefaultToolbarItem(kind: .search, placement: .bottomBar)
            ToolbarSpacer(.fixed, placement: .bottomBar)
            if isProcessing {
                ToolbarItem(placement: .bottomBar) {
                    Button(role: .destructive) {
                        client.stopChat(sessionId: sessionId)
                    } label: {
                        Image(systemName: "stop.fill")
                            .foregroundStyle(.red)
                    }
                }
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

    private static let bottomID = "bottom"

    private var isProcessing: Bool {
        client.activeSession?.meta.isProcessing == true
    }

    @ViewBuilder
    private func messageView(for message: WireMessage) -> some View {
        switch message.role {
        case .user:
            UserMessageView(text: plainText(of: message))
        case .assistant:
            AssistantMessageView(blocks: message.blocks)
                .opacity(0.85)
        }
    }

    private func plainText(of message: WireMessage) -> String {
        message.blocks.filter { $0.kind == .text }.map(\.text).joined()
    }

    private func sendDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        client.sendPrompt(text)
        draft = ""
        isInputFocused = false
    }
}
