import AppKit
import AtriumProtocol
import SwiftUI

/// Relay's desktop composer geometry, backed by the shared task service.
struct SessionChatComposer: View {
  @Bindable var composer: TaskComposer
  let provider: AgentProvider
  let isSending: Bool
  let isProcessing: Bool
  var actions: TaskActions = [.prompt, .interrupt]
  let send: () -> Void
  let interrupt: () -> Void
  var noteSourceFrame: (CGRect) -> Void = { _ in }
  @Environment(AppModel.self) private var app
  @FocusState private var isFocused: Bool
  @AppStorage("enterToSendChat") private var enterToSendChat = false

  private var prompt: String { composer.draft }
  private var images: [ComposerImage] { composer.images }
  private var edit: ConversationMessageEdit? { composer.messageEdit }
  private var dictation: ComposerDictation { composer.dictation }

  private var canSend: Bool {
    !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty || edit?.images.isEmpty == false
  }

  private var showsStop: Bool {
    isProcessing && actions.contains(.interrupt) && !canSend && !dictation.isActive && !composer.isSubmittingDictation
  }

  /// A recording counts as content: sending transcribes it first.
  private var isButtonDisabled: Bool {
    isSending || composer.isSubmittingDictation || edit?.isSubmitting == true || (edit != nil && edit?.canSubmit != true)
      || (!showsStop && ((!canSend && !dictation.isActive) || !actions.contains(.prompt)))
  }

  var body: some View {
    GlassEffectContainer {
      VStack(spacing: 0) {
        if let edit { ConversationEditContent(edit: edit) }
        if !images.isEmpty {
          SessionChatAttachmentStrip(images: $composer.images)
        }

        HStack(alignment: .bottom) {
          SessionChatInputMenu(images: $composer.images)
            .offset(y: -1)

          if edit != nil {
            ConversationEditCancelButton(action: composer.cancelEdit)
          }

          HStack(alignment: .bottom, spacing: 0) {
            ZStack(alignment: .leading) {
              if prompt.isEmpty {
                Text(edit == nil ? "Message \(provider.name)..." : "Edit message…")
                  .padding(.leading, 1)
                  .foregroundStyle(.placeholder)
                  .allowsHitTesting(false)
              }

              TextEditor(text: $composer.draft)
                .padding(.leading, -4)
                .frame(maxHeight: 350)
                .fixedSize(horizontal: false, vertical: true)
                .scrollContentBackground(.hidden)
                .focused($isFocused)
                .onKeyPress(.return, action: handleReturnKey)
                .disabled(edit?.isSubmitting == true)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .padding(6)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { noteSourceFrame($0) }

            SessionChatDictationButton(composer: composer)
          }
          .font(.body)
          .glassEffect(in: .rect(cornerRadius: 16))
          .modifier(SessionChatPasteHandler(prompt: $composer.draft, images: $composer.images, isFocused: isFocused))

          Button {
            showsStop ? interrupt() : send()
          } label: {
            Label {
              Text(showsStop ? "Stop" : edit == nil ? "Send" : "Save and Continue")
            } icon: {
              // Measure both states using Relay's Send glyph; the overlay
              // changes the visible symbol without changing its layout size.
              Image(systemName: "arrow.up")
                .hidden()
                .overlay {
                  if edit?.isSubmitting == true {
                    ProgressView()
                      .controlSize(.small)
                      .tint(.white)
                  } else {
                    Image(systemName: showsStop ? "stop.fill" : edit == nil ? "arrow.up" : "checkmark")
                  }
                }
            }
            .padding(1)
          }
          .labelStyle(.iconOnly)
          .font(.title3)
          .bold()
          .opacity(isButtonDisabled && edit?.isSubmitting != true ? 0.35 : 0.85)
          .controlSize(.large)
          .tint(showsStop ? .red : .accent)
          .buttonStyle(.glassProminent)
          .buttonBorderShape(.circle)
          .disabled(isButtonDisabled)
          .help(showsStop ? "Stop" : edit == nil ? "Send" : "Save and Continue")
          .offset(y: -2)
          .modifier(SessionChatSendShortcut(enabled: !showsStop))
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 12)
      }
      .fixedSize(horizontal: false, vertical: true)
      .disabled(edit?.isSubmitting == true)
    }
    .toolbar {
      ToolbarItem(placement: .keyboard) {
        Button("Focus") { isFocused = true }
          .keyboardShortcut("l", modifiers: .command)
      }
    }
    .task(id: edit?.id) {
      guard edit != nil else { return }
      await Task.yield()
      guard !Task.isCancelled else { return }
      isFocused = true
    }
    .task(id: app.selection) {
      await Task.yield()
      guard !Task.isCancelled else { return }
      isFocused = true
    }
    .task(id: composer.focusRequestID) {
      guard composer.focusRequestID != nil, !isFocused else { return }
      // Leave an already focused field undisturbed.
      await Task.yield()
      guard !Task.isCancelled, !isFocused else { return }
      isFocused = true
    }
  }

  private func handleReturnKey() -> KeyPress.Result {
    let modifiers = NSApp.currentEvent?.modifierFlags ?? []
    guard enterToSendChat, modifiers.intersection([.shift, .option, .command]).isEmpty else {
      return .ignored
    }
    if (canSend || dictation.isActive) && !isButtonDisabled && actions.contains(.prompt) { send() }
    return .handled
  }
}
