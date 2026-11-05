import SwiftUI

/// The editor and diffs follow the chat's font size, one point smaller.
enum EditorFontSize {
    static func matching(chat size: Double) -> CGFloat { CGFloat(size - 1) }
    static let `default` = matching(chat: ChatFontSize.default)
}

extension EnvironmentValues {
    @Entry var editorFontSize: CGFloat = EditorFontSize.default
    @Entry var fileTreeAction: (FileTreeAction) -> Void = { _ in }
}

extension FocusedValues {
    @Entry var editorPanel: EditorPanel?
    @Entry var isMainWindow: Bool?
    @Entry var latestPromptEdit: LatestPromptEdit?
}
