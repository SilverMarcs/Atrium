import AppKit
import AtriumProtocol
import SwiftUI

/// Presents the Mac composer's skill menu beside the / being typed, as a
/// menu that leaves the keyboard with the editor: letters keep narrowing the
/// list, Up and Down (or Control-P and Control-N) move the highlight, Return
/// or Tab picks the highlighted skill, and Escape closes it.
///
/// A real `NSMenu` can't do this: it tracks the keyboard itself while open.
/// The keys are read ahead of the window, so the window's own shortcuts,
/// such as Escape cancelling an edit, wait until the menu has closed.
@MainActor
final class ComposerSkillMenu {
    private let state = ComposerSkillMenuState()
    private weak var editor: NSTextView?
    /// Where the / is in the editor's text, while the menu is shown.
    private var anchor = 0
    private var panel: ComposerSkillMenuPanel?
    private var isShown = false
    private var onSelect: ((AgentSkill) -> Void)?
    private var onDismiss: (() -> Void)?
    private var keyMonitor: Any?
    private var observers: [NSObjectProtocol] = []

    /// Lists `skills`, or `status` in their place, beside the / at
    /// `location` in `editor`'s text, moving the menu to follow it.
    func show(
        _ skills: [AgentSkill],
        status: String?,
        in editor: NSTextView,
        anchoredAt location: Int,
        select: @escaping (AgentSkill) -> Void,
        dismiss: @escaping () -> Void
    ) {
        guard editor.window != nil else {
            close()
            return
        }
        if self.editor !== editor { close() }
        anchor = location
        state.show(skills)
        onSelect = select
        onDismiss = dismiss
        let rootView = ComposerSkillMenuView(skills: skills, status: status, state: state) { [weak self] skill in
            self?.onSelect?(skill)
        }
        if let panel {
            panel.hostingView.rootView = rootView
        } else {
            panel = ComposerSkillMenuPanel(rootView: rootView)
        }
        if !isShown {
            isShown = true
            self.editor = editor
            startTracking(editor)
        }
        attach()
    }

    func close() {
        guard isShown else { return }
        isShown = false
        onSelect = nil
        onDismiss = nil
        detach()
        stopTracking()
        editor = nil
    }

    // MARK: Placement

    /// Shows the panel over the editor's window while that window is key.
    private func attach() {
        guard isShown, let panel, let window = editor?.window, window.isKeyWindow else {
            detach()
            return
        }
        reposition()
        if panel.parent !== window {
            panel.parent?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
    }

    private func detach() {
        guard let panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    /// Sits the menu just above the line with the /, its names lined up with
    /// the name being typed after it, or below the line when there's no room
    /// above.
    private func reposition() {
        guard let editor, let panel, anchor < (editor.string as NSString).length,
              let screen = editor.window?.screen ?? NSScreen.main else { return }
        let size = panel.hostingView.fittingSize
        let slash = editor.firstRect(forCharacterRange: NSRange(location: anchor, length: 1), actualRange: nil)
        let visible = screen.visibleFrame
        var origin = NSPoint(
            x: slash.maxX - ComposerSkillMenuMetrics.textOffset,
            y: slash.maxY + ComposerSkillMenuMetrics.lineSpacing
        )
        if origin.y + size.height > visible.maxY {
            origin.y = slash.minY - ComposerSkillMenuMetrics.lineSpacing - size.height
        }
        origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
        let frame = NSRect(origin: origin, size: size).integral
        guard frame != panel.frame else { return }
        panel.setFrame(frame, display: true)
        panel.invalidateShadow()
    }

    // MARK: Tracking

    /// Follows the editor as it grows, scrolls, and reflows, its window as
    /// it resizes and gains and loses key, and the keyboard.
    private func startTracking(_ editor: NSTextView) {
        let center = NotificationCenter.default
        let reposition: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.reposition() }
        }
        var views: [NSView] = [editor]
        if let scrollView = editor.enclosingScrollView {
            views.append(scrollView)
            scrollView.contentView.postsBoundsChangedNotifications = true
            observers.append(center.addObserver(
                forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main, using: reposition
            ))
        }
        for view in views {
            view.postsFrameChangedNotifications = true
            observers.append(center.addObserver(
                forName: NSView.frameDidChangeNotification, object: view, queue: .main, using: reposition
            ))
        }
        if let window = editor.window {
            observers.append(center.addObserver(
                forName: NSWindow.didResizeNotification, object: window, queue: .main, using: reposition
            ))
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
                observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.attach() }
                })
            }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.handle(event) ?? false }
            return handled ? nil : event
        }
    }

    private func stopTracking() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    /// Handles a key meant for the menu, leaving the rest to the editor. A
    /// composition, such as Japanese input, keeps every key.
    private func handle(_ event: NSEvent) -> Bool {
        guard let editor, let panel, panel.isVisible, event.window === editor.window,
              editor.window?.firstResponder === editor, !editor.hasMarkedText() else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let key = event.specialKey
        if modifiers.isEmpty, key == .upArrow || key == .downArrow {
            state.moveHighlight(by: key == .upArrow ? -1 : 1)
        } else if modifiers == .control, let letter = event.charactersIgnoringModifiers, letter == "p" || letter == "n" {
            state.moveHighlight(by: letter == "p" ? -1 : 1)
        } else if modifiers.isEmpty, key == .carriageReturn || key == .enter || key == .tab {
            guard let highlighted = state.highlighted else { return false }
            onSelect?(highlighted)
        } else if modifiers.isEmpty, event.keyCode == Self.escapeKeyCode {
            onDismiss?()
        } else {
            return false
        }
        return true
    }

    private static let escapeKeyCode: UInt16 = 53
}

/// What the skill menu lists, and which skill Return would pick. The
/// keyboard and the pointer both move the highlight, as in a menu.
@MainActor
@Observable
final class ComposerSkillMenuState {
    private(set) var skills: [AgentSkill] = []
    var highlightedID: AgentSkill.ID?

    var highlighted: AgentSkill? {
        skills.first { $0.id == highlightedID }
    }

    /// Lists `skills`, highlighting the first whenever the list changes, as
    /// typing narrows it.
    func show(_ skills: [AgentSkill]) {
        guard skills != self.skills else { return }
        self.skills = skills
        highlightedID = skills.first?.id
    }

    /// Moves the highlight `offset` rows, wrapping past either end.
    func moveHighlight(by offset: Int) {
        guard !skills.isEmpty else { return }
        let count = skills.count
        let current = skills.firstIndex { $0.id == highlightedID } ?? (offset > 0 ? -1 : 0)
        highlightedID = skills[((current + offset) % count + count) % count].id
    }
}

extension View {
    /// Shows `menu` at the / being typed in `composer`'s draft while
    /// `isPresented` and the editor has focus. Escape sets `isPresented` to
    /// false.
    func composerSkillMenu(
        _ menu: ComposerSkillMenu,
        composer: TaskComposer,
        isPresented: Binding<Bool>,
        skills: [AgentSkill],
        status: String?,
        select: @escaping (AgentSkill) -> Void
    ) -> some View {
        let anchor = isPresented.wrappedValue && composer.isFocused ? composer.skillQuery?.range.location : nil
        return onChange(of: ComposerSkillMenuContent(anchor: anchor, skills: skills, status: status), initial: true) {
            guard let anchor, let editor = composer.textEditor as? NSTextView else {
                menu.close()
                return
            }
            menu.show(skills, status: status, in: editor, anchoredAt: anchor, select: select) {
                isPresented.wrappedValue = false
            }
        }
        .onDisappear { menu.close() }
    }
}

private struct ComposerSkillMenuContent: Equatable {
    let anchor: Int?
    let skills: [AgentSkill]
    let status: String?
}
