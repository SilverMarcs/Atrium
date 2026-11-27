import AppKit
import SwiftUI

extension View {
    /// Keeps the inspector column at the width last dragged for each chat on
    /// this Mac. A chat that was never resized opens at the last width set.
    func remembersInspectorWidth(for chat: TaskRef?) -> some View {
        background(InspectorWidthMemory(chat: chat))
    }
}

/// SwiftUI's inspector column has no width binding, so this finds the split
/// view item it sits in, saves the item's width after a drag and moves the
/// divider when the chat changes or anything but the user moves it.
struct InspectorWidthMemory: NSViewRepresentable {
    private static let widthsKey = "inspectorWidths"
    let chat: TaskRef?

    private static func key(for chat: TaskRef) -> String {
        "\(chat.hostID)/\(chat.taskID)"
    }

    static func transfer(from draft: TaskRef, to task: TaskRef) {
        let defaults = UserDefaults.standard
        var widths = defaults.dictionary(forKey: widthsKey) as? [String: Double] ?? [:]
        guard let width = widths.removeValue(forKey: key(for: draft)) else { return }
        let taskKey = key(for: task)
        widths[taskKey] = widths[taskKey] ?? width
        defaults.set(widths, forKey: widthsKey)
    }

    func makeNSView(context: Context) -> TrackerView { TrackerView() }

    func updateNSView(_ view: TrackerView, context: Context) {
        view.key = chat.map(Self.key(for:))
    }

    final class TrackerView: NSView {
        private static let lastWidthKey = "inspectorLastWidth"

        var key: String? {
            didSet {
                guard key != oldValue else { return }
                restore()
            }
        }
        private weak var splitView: NSSplitView?
        /// The split view's arranged subview holding the inspector.
        private weak var pane: NSView?
        private weak var item: NSSplitViewItem?
        private var resizeObserver: NSObjectProtocol?
        private var isRestoring = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            detach()
            guard window != nil else { return }
            // The split view sets up its items after this view joins the window.
            DispatchQueue.main.async { [weak self] in
                guard let self, window != nil else { return }
                attach()
                restore()
            }
        }

        private func attach() {
            var view: NSView = self
            while let parent = view.superview {
                if let split = parent as? NSSplitView, split.isVertical,
                   let controller = split.delegate as? NSSplitViewController,
                   let item = controller.splitViewItems.first(where: { $0.viewController.view.isDescendant(of: view) }) {
                    splitView = split
                    pane = view
                    self.item = item
                    break
                }
                view = parent
            }
            guard let splitView, let item else { return }
            resizeObserver = NotificationCenter.default.addObserver(
                forName: NSSplitView.didResizeSubviewsNotification,
                object: splitView,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.splitViewDidResize() }
            }
        }

        private func detach() {
            if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
            resizeObserver = nil
            splitView = nil
            pane = nil
            item = nil
        }

        /// A drag of the divider sets the chat's width; anything else that
        /// moves it, such as SwiftUI reopening the inspector at its ideal
        /// width, is put back. Resizing the window squeezes it freely.
        private func splitViewDidResize() {
            guard !isRestoring, let item, !item.isCollapsed,
                  let window, !window.inLiveResize else { return }
            if NSEvent.pressedMouseButtons & 1 != 0 {
                save()
            } else {
                restore()
            }
        }

        private func save() {
            guard let key, let pane, let item else { return }
            let width = Double(pane.frame.width)
            guard width >= item.minimumThickness else { return }
            let defaults = UserDefaults.standard
            var widths = defaults.dictionary(forKey: InspectorWidthMemory.widthsKey) as? [String: Double] ?? [:]
            guard widths[key] != width else { return }
            widths[key] = width
            defaults.set(widths, forKey: InspectorWidthMemory.widthsKey)
            defaults.set(width, forKey: Self.lastWidthKey)
        }

        private func restore() {
            guard let key, let splitView, let pane, let item, !item.isCollapsed,
                  let index = splitView.arrangedSubviews.firstIndex(of: pane), index > 0 else { return }
            let defaults = UserDefaults.standard
            let widths = defaults.dictionary(forKey: InspectorWidthMemory.widthsKey) as? [String: Double] ?? [:]
            guard let saved = widths[key] ?? (defaults.object(forKey: Self.lastWidthKey) as? Double) else { return }
            let width = CGFloat(saved)
            guard abs(pane.frame.width - width) >= 1 else { return }
            isRestoring = true
            defer { isRestoring = false }
            // The divider sits before the pane, whose trailing edge stays put;
            // the split view clamps to the column's minimum and maximum. An
            // overlaid inspector doesn't leave room for the divider, so the
            // first move can land a point out.
            let position = pane.frame.maxX - width - splitView.dividerThickness
            splitView.setPosition(position, ofDividerAt: index - 1)
            let error = pane.frame.width - width
            if abs(error) >= 1 {
                splitView.setPosition(position + error, ofDividerAt: index - 1)
            }
        }
    }
}
