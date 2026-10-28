import SwiftUI

/// Scrolls to the message being edited, or the newest message, when the composer gains focus.
///
/// Focus is observed here rather than in `TaskChatView.body`, so a focus
/// change re-evaluates only this modifier. Interactive keyboard dismissal ends
/// with UIKit resigning the field in the same run-loop turn that commits the
/// timeline's final inset and offset correction. Rebuilding and diffing every
/// timeline row in that turn delays the correction, so the timeline settles
/// after the composer.
struct ScrollOnComposerFocus: ViewModifier {
    @Environment(TaskComposer.self) private var composer
    @State private var scrollTask: Task<Void, Never>?

    let scrollToLatest: () -> Void
    let scrollToEditingMessage: (String) -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: composer.isFocused) { _, focused in
                scrollTask?.cancel()
                guard focused else { return }
                // The wait lets the keyboard's safe area apply first.
                let editingMessageID = composer.messageEdit?.messageID
                scrollTask = Task {
                    do {
                        try await Task.sleep(for: .milliseconds(1))
                    } catch {
                        return
                    }
                    guard !Task.isCancelled, composer.messageEdit?.messageID == editingMessageID else { return }
                    if let editingMessageID { scrollToEditingMessage(editingMessageID) }
                    else { scrollToLatest() }
                }
            }
            .onDisappear {
                scrollTask?.cancel()
            }
    }
}

extension View {
    /// Scrolls to the edit target or newest message when the composer gains focus.
    func scrollsOnComposerFocus(scrollToLatest: @escaping () -> Void, scrollToEditingMessage: @escaping (String) -> Void) -> some View {
        modifier(ScrollOnComposerFocus(scrollToLatest: scrollToLatest, scrollToEditingMessage: scrollToEditingMessage))
    }
}
