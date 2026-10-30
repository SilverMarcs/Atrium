import SwiftUI

/// Keeps a recording tied to the visible task, and explains a failed one.
struct ComposerDictationLifecycle: ViewModifier {
    let composer: TaskComposer
    @Environment(DictationSettings.self) private var settings
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .onChange(of: settings.isEnabled) {
                if !settings.isEnabled { composer.dictation.cancel() }
            }
            .onChange(of: scenePhase) {
                if scenePhase == .background { composer.dictation.cancel() }
            }
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

extension View {
    func composerDictationLifecycle(_ composer: TaskComposer) -> some View {
        modifier(ComposerDictationLifecycle(composer: composer))
    }
}
