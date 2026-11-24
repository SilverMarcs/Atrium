import AppKit
import SwiftUI

/// Collapses the window's last split column, the chat's pane, while it's
/// closed. A NavigationSplitView always shows its detail column, so this
/// reaches the AppKit split view item behind it, from a view in the column
/// beside it (a collapsed column's own views may not update).
///
/// Dragging the column shut, or open, asks `onDrag` to follow; when it
/// doesn't, the column goes back.
struct PaneColumnCollapse: NSViewRepresentable {
    let isCollapsed: Bool
    /// The user dragged the column to this state; says whether the pane follows.
    let onDrag: (_ isCollapsed: Bool) -> Bool
    /// The column started or finished sliding open or shut.
    let onMoving: (_ isMoving: Bool) -> Void

    func makeNSView(context: Context) -> PaneColumnCollapseView {
        PaneColumnCollapseView()
    }

    func updateNSView(_ view: PaneColumnCollapseView, context: Context) {
        view.onDrag = onDrag
        view.onMoving = onMoving
        view.wantsCollapsed = isCollapsed
        view.apply(animated: context.transaction.animation != nil && !context.transaction.disablesAnimations)
    }
}

final class PaneColumnCollapseView: NSView {
    var wantsCollapsed = true
    var onDrag: (Bool) -> Bool = { _ in false }
    var onMoving: (Bool) -> Void = { _ in }
    private weak var column: NSSplitViewItem?
    private var observation: NSKeyValueObservation?
    /// Set while this collapses or opens the column, so only drags report back.
    private var isApplying = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        column = nil
        observation = nil
        apply(animated: false)
    }

    func apply(animated: Bool) {
        guard let column = paneColumn() else { return }
        guard column.isCollapsed != wantsCollapsed else { return }
        isApplying = true
        if animated {
            onMoving(true)
            NSAnimationContext.runAnimationGroup { _ in
                column.animator().isCollapsed = wantsCollapsed
            } completionHandler: { [weak self] in
                self?.isApplying = false
                self?.onMoving(false)
            }
        } else {
            column.isCollapsed = wantsCollapsed
            isApplying = false
        }
    }

    /// The last column of the nearest split view controller above this view:
    /// NavigationSplitView's detail column. The inspector's split view
    /// controller sits further out, around the whole NavigationSplitView.
    private func paneColumn() -> NSSplitViewItem? {
        if let column { return column }
        var view = superview
        while let current = view {
            if let split = current as? NSSplitView,
               let controller = split.delegate as? NSSplitViewController,
               controller.splitViewItems.count == 3,
               let last = controller.splitViewItems.last {
                last.canCollapse = true
                column = last
                observation = last.observe(\.isCollapsed, options: [.new]) { [weak self] item, _ in
                    let isCollapsed = item.isCollapsed
                    Task { @MainActor in self?.columnDidChange(isCollapsed) }
                }
                return last
            }
            view = current.superview
        }
        return nil
    }

    private func columnDidChange(_ isCollapsed: Bool) {
        guard !isApplying, isCollapsed != wantsCollapsed else { return }
        if onDrag(isCollapsed) {
            wantsCollapsed = isCollapsed
        } else {
            apply(animated: true)
        }
    }
}
