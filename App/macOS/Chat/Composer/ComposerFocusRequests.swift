import SwiftUI

/// Focuses the Mac composer when its chat is selected, when a message edit
/// or dictated text lands in it, and on ⌘L.
private struct ComposerFocusRequests: ViewModifier {
    @Environment(TaskComposer.self) private var composer
    @Environment(AppModel.self) private var app

    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItem(placement: .keyboard) {
                    Button("Focus") { composer.isFocused = true }
                        .keyboardShortcut("l", modifiers: .command)
                }
            }
            .task(id: app.selection) {
                await Task.yield()
                guard !Task.isCancelled else { return }
                composer.isFocused = true
            }
            .task(id: composer.focusRequestID) {
                guard composer.focusRequestID != nil else { return }
                await Task.yield()
                guard !Task.isCancelled else { return }
                composer.isFocused = true
            }
    }
}

extension View {
    func composerFocusRequests() -> some View {
        modifier(ComposerFocusRequests())
    }
}
