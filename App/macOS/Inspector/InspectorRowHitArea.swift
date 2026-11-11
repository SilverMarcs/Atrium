import SwiftUI

extension View {
    /// Stretches a row's content over the whole row, so a click anywhere in
    /// it, beside or above the label too, lands on the row's own button.
    /// Pair it with `listRowInsets(.vertical, 0)` on the row, which hands
    /// the list's own spacing to the content.
    func fillsInspectorRow() -> some View {
        modifier(FillsInspectorRow())
    }
}

private struct FillsInspectorRow: ViewModifier {
    @Environment(\.defaultMinListRowHeight) private var minHeight

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .leading)
            .contentShape(.rect)
    }
}
