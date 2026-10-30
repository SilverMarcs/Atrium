import SwiftUI

/// Keeps a recording tied to the visible chat, as in Relay.
struct SessionChatDictationLifecycle: ViewModifier {
  let composer: ComposerDraft
  @Environment(DictationSettings.self) private var settings

  func body(content: Content) -> some View {
    content
      .onChange(of: settings.isEnabled) {
        if !settings.isEnabled { composer.dictation.cancel() }
      }
      // Each task's view is replaced when another opens.
      .onDisappear { composer.dictation.cancel() }
      .alert("Couldn’t Dictate", isPresented: Binding(
        get: { composer.dictation.error != nil },
        set: { if !$0 { composer.dictation.error = nil } }
      )) {
        Button("OK") { composer.dictation.error = nil }
      } message: {
        Text(composer.dictation.error ?? "")
      }
  }
}
