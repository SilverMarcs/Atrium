import AppKit
import SwiftUI

/// Relay's desktop composer geometry, backed by the shared task service.
struct SessionChatComposer: View {
  @Binding var prompt: String
  @Binding var images: [ComposerImage]
  let provider: AgentProvider
  let isSending: Bool
  let isProcessing: Bool
  var actions: TaskActions = [.prompt, .interrupt]
  let send: () -> Void
  let interrupt: () -> Void
  var noteSourceFrame: (CGRect) -> Void = { _ in }
  @Environment(AppState.self) private var appState
  @FocusState private var isFocused: Bool
  @AppStorage("enterToSendChat") private var enterToSendChat = false

  private var canSend: Bool {
    !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty
  }

  private var showsStop: Bool { isProcessing && actions.contains(.interrupt) && !canSend }

  private var isButtonDisabled: Bool {
    isSending || (!showsStop && (!canSend || !actions.contains(.prompt)))
  }

  var body: some View {
    GlassEffectContainer {
      VStack(spacing: 0) {
        if !images.isEmpty {
          SessionChatAttachmentStrip(images: $images)
        }

        HStack(alignment: .bottom) {
          SessionChatInputMenu(images: $images)
            .offset(y: -1)

          HStack(alignment: .bottom, spacing: 0) {
            TextField("Message \(provider.name)...", text: $prompt, axis: .vertical)
              .textFieldStyle(.plain)
              .font(.body)
              .focused($isFocused)
              .lineLimit(1 ... 7)
              .padding(.horizontal, 4)
              .padding(8)
              .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { noteSourceFrame($0) }
              .onKeyPress(.return, action: handleReturnKey)
          }
          .glassEffect(in: .rect(cornerRadius: 20))

          Button {
            showsStop ? interrupt() : send()
          } label: {
            Label {
              Text(showsStop ? "Stop" : "Send")
            } icon: {
              // Measure both states using Relay's Send glyph; the overlay
              // changes the visible symbol without changing its layout size.
              Image(systemName: "arrow.up")
                .hidden()
                .overlay {
                  Image(systemName: showsStop ? "stop.fill" : "arrow.up")
                }
            }
            .padding(1)
          }
          .labelStyle(.iconOnly)
          .font(.title3)
          .bold()
          .opacity(isButtonDisabled ? 0.35 : 0.85)
          .controlSize(.large)
          .tint(showsStop ? .red : .accent)
          .buttonStyle(.glassProminent)
          .buttonBorderShape(.circle)
          .disabled(isButtonDisabled)
          .help(showsStop ? "Stop" : "Send")
          .offset(y: -2)
          .modifier(SessionChatSendShortcut(enabled: !showsStop))
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 12)
      }
      .fixedSize(horizontal: false, vertical: true)
    }
    .toolbar {
      ToolbarItem(placement: .keyboard) {
        Button("Focus") { isFocused = true }
          .keyboardShortcut("l", modifiers: .command)
      }
    }
    .task(id: appState.selectedThreadID) {
      await Task.yield()
      guard !Task.isCancelled else { return }
      isFocused = true
    }
  }

  private func handleReturnKey() -> KeyPress.Result {
    let modifiers = NSApp.currentEvent?.modifierFlags ?? []
    guard enterToSendChat, modifiers.intersection([.shift, .option, .command]).isEmpty else {
      return .ignored
    }
    if canSend && !isSending && actions.contains(.prompt) { send() }
    return .handled
  }
}
