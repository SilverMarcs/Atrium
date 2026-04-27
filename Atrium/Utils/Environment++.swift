import SwiftUI

enum EditorFontSize {
    static let key = "editorFontSize"
    static let `default`: Double = 12
    static let min: Double = 9
    static let max: Double = 24
}

extension EnvironmentValues {
    @Entry var isDetachedEditor: Bool = false
    @Entry var editorFontSize: CGFloat = CGFloat(EditorFontSize.default)
    @Entry var fileTreeAction: (FileTreeAction) -> Void = { _ in }
    @Entry var showInFileTree: (URL) -> Void = { _ in }
}

extension FocusedValues {
    @Entry var editorPanel: EditorPanel?
    @Entry var isMainWindow: Bool?
}
