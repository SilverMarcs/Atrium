import SwiftUI
import AppKit

struct ChatInputArea: View {
    @Bindable var chat: Chat
    @FocusState private var isFocused: Bool
    @Environment(AppState.self) var state
    @AppStorage("enterToSendChat") private var enterToSendChat: Bool = false
    /// Set when the popover dismisses via Escape or an outside click, so we
    /// stay closed even though the user's "/foo" prefix would otherwise
    /// trigger us again. Cleared once the slash sequence ends (whitespace
    /// or the leading "/" gone), letting the next "/" reopen the menu.
    @State private var slashMenuSuppressed = false

    private var session: AgentSession { chat.session }

    private var showsStop: Bool { session.isProcessing && !canSend }
    private var canSend: Bool {
        !chat.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !chat.pendingAttachments.isEmpty
    }

    /// Range of the trailing "/command" token in `chat.prompt`, if the user is
    /// currently typing one. The token must start with "/" at the beginning of
    /// the prompt or after whitespace, and must run to the end of the prompt
    /// without any intervening whitespace.
    private var slashTokenRange: Range<String.Index>? {
        let prompt = chat.prompt
        guard !prompt.isEmpty else { return nil }
        var idx = prompt.endIndex
        while idx > prompt.startIndex {
            let prev = prompt.index(before: idx)
            let ch = prompt[prev]
            if ch.isWhitespace || ch.isNewline { return nil }
            if ch == "/" {
                if prev == prompt.startIndex {
                    return prev..<prompt.endIndex
                }
                let before = prompt[prompt.index(before: prev)]
                if before.isWhitespace || before.isNewline {
                    return prev..<prompt.endIndex
                }
                return nil
            }
            idx = prev
        }
        return nil
    }

    private var slashQuery: String? {
        guard let range = slashTokenRange else { return nil }
        return String(chat.prompt[range].dropFirst())
    }

    private var filteredCommands: [AvailableCommand] {
        guard let query = slashQuery else { return [] }
        guard !query.isEmpty else { return session.availableCommands }
        let needle = query.lowercased()
        return session.availableCommands.filter { $0.name.lowercased().hasPrefix(needle) }
    }

    private var showSlashMenu: Bool {
        slashQuery != nil && !filteredCommands.isEmpty && !slashMenuSuppressed
    }

    private var slashMenuBinding: Binding<Bool> {
        Binding(
            get: { showSlashMenu },
            set: { newValue in
                // Only treat this as Escape / outside-click when the user is
                // still inside a slash token. If the popover is closing
                // because the slash sequence already ended (space typed,
                // command accepted), don't latch suppression — that would
                // block the next "/" from reopening the menu.
                if !newValue, slashQuery != nil { slashMenuSuppressed = true }
            }
        )
    }

    var body: some View {
        GlassEffectContainer {
            HStack(alignment: .bottom) {
                ChatInputMenu(chat: chat)
                    .offset(y: -1)

                VStack(alignment: .leading) {
                    if !chat.pendingAttachments.isEmpty {
                        AttachmentThumbnails(chat: chat)
                        .padding(.top, 4)
                    }

                    TextEditor(text: $chat.prompt)
                        .findDisabled()
                        .replaceDisabled()
                        .padding(.leading, -4)
                        .frame(maxHeight: 350)
                        .fixedSize(horizontal: false, vertical: true)
                        .scrollContentBackground(.hidden)
                        .focused($isFocused)
                        .overlay(alignment: .leading) {
                             if chat.prompt.isEmpty {
                                 Text("Message \(chat.provider.rawValue)...")
                                    .padding(.leading, 1)
                                    .foregroundStyle(.placeholder)
                                    .allowsHitTesting(false)
                             }
                        }
                       .font(.body)
                       .onKeyPress(.return) { handleReturnKey() }
                       .onKeyPress(.tab) {
                           if showSlashMenu, let top = filteredCommands.first {
                               applyCommand(top)
                               return .handled
                           }
                           return .ignored
                       }
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .padding(6)
                .glassEffect(in: .rect(cornerRadius: 16))
                .popover(
                    isPresented: slashMenuBinding,
                    attachmentAnchor: .point(.topLeading),
                    arrowEdge: .bottom
                ) {
                    SlashCommandMenu(commands: filteredCommands) { cmd in
                        applyCommand(cmd)
                    }
                }

                Button {
                    showsStop ? session.stopStreaming() : send()
                } label: {
                    Label(showsStop ? "Stop" : "Send", systemImage: showsStop ? "stop.fill" : "arrow.up")
                        .labelStyle(.iconOnly)
                        .font(.system(size: 15)).fontWeight(.bold)
                }
                .opacity(0.85)
                .controlSize(.large)
                .tint(showsStop ? .red : .accent)
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.circle)
                .disabled(session.isConnecting || (session.isProcessing && canSend ? !session.canSteer : !session.isProcessing && !canSend))
                .help(showsStop ? "Stop" : "Send")
                .offset(y: -2)
                .if(!session.isProcessing || session.canSteer && canSend) { view in
                    view.keyboardShortcut(.return, modifiers: [.command])
                }
            }
            .padding(12)
        }
        .imagePasteHandler(chat: chat)
        .onChange(of: slashQuery) { _, newValue in
            // Once the user backs out of the slash sequence (cleared the
            // "/" or typed past it), drop the suppression flag so the next
            // "/" they type reopens the menu.
            if newValue == nil { slashMenuSuppressed = false }
        }
        .toolbar {
            ToolbarItem(placement: .keyboard) {
               Button("Focus") {
                   isFocused = true
               }
               .keyboardShortcut("l", modifiers: .command)
            }
        }
        .task(id: state.selectedChat) {
                isFocused = true
        }
    }

    private func handleReturnKey() -> KeyPress.Result {
        let mods = NSApp.currentEvent?.modifierFlags ?? []
        let isPlainReturn = !mods.contains(.shift) && !mods.contains(.option) && !mods.contains(.command)

        if enterToSendChat, isPlainReturn {
            if canSend, !session.isConnecting, !session.isProcessing || session.canSteer {
                send()
            }
            return .handled
        }

        return .ignored
    }

    private func applyCommand(_ cmd: AvailableCommand) {
        if let range = slashTokenRange {
            chat.prompt.replaceSubrange(range, with: "/\(cmd.name) ")
        } else {
            chat.prompt = "/\(cmd.name) "
        }
    }

    private func send() {
        let text = chat.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = chat.pendingAttachments
        guard !text.isEmpty || !attachments.isEmpty else { return }
        if chat.sendMessage(text, attachments: attachments) { chat.prompt = "" }
    }
}

extension View {
    @ViewBuilder
    func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}
