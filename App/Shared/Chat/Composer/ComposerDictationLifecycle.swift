import SwiftUI

/// Explains a failed recording. On the Mac a recording is tied to the
/// visible task; on iOS it carries on when its chat closes or the app leaves
/// the screen, and finishes when the chat is opened again.
struct ComposerDictationLifecycle: ViewModifier {
    let composer: TaskComposer
    @Environment(DictationSettings.self) private var settings
    #if os(macOS)
    @Environment(\.scenePhase) private var scenePhase
    #endif

    func body(content: Content) -> some View {
        content
            .onChange(of: settings.isEnabled) {
                guard !settings.isEnabled else { return }
                composer.dictation.cancel()
                // Including a recording for a chat that isn't open.
                DictationMicrophone.shared.owner?.cancel()
            }
            #if os(macOS)
            .onChange(of: scenePhase) {
                if scenePhase == .background { composer.dictation.cancel() }
            }
            .onDisappear { composer.dictation.cancel() }
            #endif
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
