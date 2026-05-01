import SwiftUI

struct QuickPanelView: View {
    @Bindable var controller: QuickPanelController
    var onHeightChange: (QuickPanelHeight) -> Void
    var onDismiss: () -> Void

    var body: some View {
        QuickPanelInnerView(
            chat: controller.chat,
            controller: controller,
            onHeightChange: onHeightChange,
            onDismiss: onDismiss
        )
        // Re-mount whenever a fresh chat is swapped in by `reset()`, so the
        // input field, focus state, and toolbars start clean.
        .id(controller.chat.id)
    }
}

private struct QuickPanelInnerView: View {
    @Bindable var chat: Chat
    let controller: QuickPanelController
    let onHeightChange: (QuickPanelHeight) -> Void
    let onDismiss: () -> Void

    @FocusState private var isFocused: Bool
    private let catalog = ModelCatalog.shared

    private var session: ACPSession { chat.session }

    private var canChangeProvider: Bool {
        chat.messages.isEmpty && !session.isConnected && !session.isConnecting
    }

    private var canSend: Bool {
        !chat.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !chat.pendingAttachments.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            inputBar
                .padding(15)
                .frame(height: QuickPanelHeight.collapsed.value)

            if !chat.pendingAttachments.isEmpty {
                AttachmentThumbnails(chat: chat)
                    .padding(.horizontal, 15)
                    .padding(.bottom, 10)
            }

            if !chat.messages.isEmpty {
                Divider()
                messagesList
                Divider()
                bottomBar
            } else {
                // Anchor input + attachments to the top while the panel is
                // expanded, so the empty space sits below — matching LynkChat.
                Spacer(minLength: 0)
            }
        }
        .frame(width: 650)
        .task { isFocused = true }
        .onChange(of: chat.messages.count) { syncHeight() }
        .onChange(of: chat.pendingAttachments.count) { syncHeight() }
        .onExitCommand(perform: onDismiss)
        .imagePasteHandler(chat: chat)
    }

    private func syncHeight() {
        let shouldExpand = !chat.messages.isEmpty || !chat.pendingAttachments.isEmpty
        onHeightChange(shouldExpand ? .expanded : .collapsed)
    }

    private var inputBar: some View {
        HStack(spacing: 12) {
            providerControl

            ZStack(alignment: .leading) {
                if chat.prompt.isEmpty {
                    Text("Ask \(chat.provider.rawValue)…")
                        .foregroundStyle(.placeholder)
                        .padding(.leading, 1)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $chat.prompt)
                    .focused($isFocused)
                    .scrollContentBackground(.hidden)
                    .padding(.leading, -4)
                    .onKeyPress(.return) {
                        if NSEvent.modifierFlags.contains(.shift) { return .ignored }
                        send()
                        return .handled
                    }
            }
            .font(.system(size: 22))

            Button(action: { session.isProcessing ? session.stopStreaming() : send() }) {
                Image(systemName: session.isProcessing ? "stop.circle.fill" : "arrow.up.circle.fill")
                    .font(.largeTitle)
                    .fontWeight(.semibold)
                    .scaleEffect(1.1)
            }
            .foregroundStyle(.white, session.isProcessing ? AnyShapeStyle(Color.red) : AnyShapeStyle(Color.accentColor))
            .buttonStyle(.plain)
            .disabled(!session.isProcessing && !canSend)
        }
    }

    @ViewBuilder
    private var providerControl: some View {
        if canChangeProvider {
            Menu {
                ForEach(AgentProvider.allCases, id: \.self) { provider in
                    Menu {
                        let models = catalog.models(for: provider)
                        if models.isEmpty {
                            Text("No models loaded")
                        } else {
                            ForEach(models) { model in
                                Button {
                                    controller.selectProviderAndModel(provider, model: model.rawValue)
                                } label: {
                                    HStack {
                                        Text(model.name)
                                        if chat.provider == provider && chat.model == model.rawValue {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                        }
                    } label: {
                        Label(provider.rawValue, image: provider.imageName)
                    }
                }
            } label: {
                providerIcon
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .fixedSize()
        } else {
            providerIcon
        }
    }

    private var providerIcon: some View {
        Image(chat.provider.imageName)
            .resizable()
            .scaledToFit()
            .frame(width: 24, height: 24)
            .foregroundStyle(chat.provider.color)
    }

    private var messagesList: some View {
        // Inverted: newest message at the top. Scroll the list to the top
        // when a new turn lands so the user always sees the latest exchange.
        ScrollViewReader { proxy in
            List {
                Color.clear.frame(height: 1).id("top").listRowSeparator(.hidden)
                if let error = session.error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .listRowSeparator(.hidden)
                        .foregroundStyle(.red)
                }
                ForEach(chat.messages.reversed()) { message in
                    MessageRow(message: message)
                        .listRowSeparator(.hidden)
                }
            }
            .scrollContentBackground(.hidden)
            .onChange(of: chat.messages.count) {
                withAnimation { proxy.scrollTo("top", anchor: .top) }
            }
        }
    }

    private var bottomBar: some View {
        HStack {
            Button {
                controller.reset()
                onHeightChange(.collapsed)
                isFocused = true
            } label: {
                Image(systemName: "delete.left")
                    .imageScale(.medium)
            }
            .keyboardShortcut(.delete, modifiers: [.command, .shift])
            .help("Clear chat (⇧⌘⌫)")
            Spacer()
        }
        .foregroundStyle(.secondary)
        .buttonStyle(.plain)
        .padding(7)
    }

    private func send() {
        let text = chat.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = chat.pendingAttachments
        guard !text.isEmpty || !attachments.isEmpty else { return }
        chat.prompt = ""
        chat.sendMessage(text, attachments: attachments)
    }
}
