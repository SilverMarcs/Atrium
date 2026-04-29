import SwiftUI
import AppKit
import ACPModel

struct ACPInputArea: View {
    @Bindable var chat: Chat
    @FocusState private var isFocused: Bool
    @Environment(AppState.self) var state
    @AppStorage("enterToSendChat") private var enterToSendChat: Bool = false
    /// Set when the popover dismisses via Escape or an outside click, so we
    /// stay closed even though the user's "/foo" prefix would otherwise
    /// trigger us again. Cleared once the slash sequence ends (whitespace
    /// or the leading "/" gone), letting the next "/" reopen the menu.
    @State private var slashMenuSuppressed = false

    private var session: ACPSession { chat.session }

    private var canSend: Bool {
        !chat.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !chat.pendingAttachments.isEmpty
    }

    private var slashQuery: String? {
        let prompt = chat.prompt
        guard prompt.hasPrefix("/") else { return nil }
        let afterSlash = prompt.dropFirst()
        // Once whitespace appears after the slash, the user has finished
        // typing the command name — drop the popover instead of keeping it
        // open while they type the rest of the line.
        if afterSlash.contains(where: { $0.isWhitespace || $0.isNewline }) {
            return nil
        }
        return String(afterSlash)
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
                // Escape / outside-click. Suppress until the slash sequence
                // ends — don't touch `chat.prompt`, the user can still send
                // "/foo" as literal text.
                if !newValue { slashMenuSuppressed = true }
            }
        )
    }

    var body: some View {
        GlassEffectContainer {
            HStack(alignment: .bottom) {
                ACPInputMenu(chat: chat)
                    .offset(y: -1)

                VStack(alignment: .leading) {
                    if !chat.pendingAttachments.isEmpty {
                        AttachmentThumbnails(chat: chat)
                    }

                    TextEditor(text: $chat.prompt)
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
                        chat.prompt = "/\(cmd.name) "
                    }
                }

                Button {
                    session.isProcessing ? session.stopStreaming() : send()
                } label: {
                    Image(systemName: session.isProcessing ? "stop.fill" : "arrow.up")
                        .font(.system(size: 15)).fontWeight(.bold)
                }
                .opacity(0.85)
                .controlSize(.large)
                .tint(session.isProcessing ? .red : .accent)
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.circle)
                .disabled(!session.isProcessing && (!canSend || session.isConnecting))
                .offset(y: -2)
                .if(!session.isProcessing) { view in
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
            if canSend, !session.isProcessing, !session.isConnecting {
                send()
            }
            return .handled
        }

        return .ignored
    }

    private func send() {
        let text = chat.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = chat.pendingAttachments
        guard !text.isEmpty || !attachments.isEmpty else { return }
        chat.prompt = ""
        chat.sendMessage(text, attachments: attachments)
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