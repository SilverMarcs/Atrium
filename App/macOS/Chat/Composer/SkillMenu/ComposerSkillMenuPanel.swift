import AppKit
import SwiftUI

/// The window behind the Mac skill menu: borderless, in Liquid Glass like a
/// menu, and never key, so the editor keeps the keyboard while the menu is up
/// and typing carries on narrowing it.
final class ComposerSkillMenuPanel: NSPanel {
    let hostingView: ComposerSkillMenuHostingView

    init(rootView: ComposerSkillMenuView) {
        hostingView = ComposerSkillMenuHostingView(rootView: rootView)
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        becomesKeyOnlyIfNeeded = true

        // Liquid Glass, as macOS draws its own menus.
        let glass = NSGlassEffectView()
        glass.cornerRadius = ComposerSkillMenuMetrics.cornerRadius
        glass.contentView = hostingView
        contentView = glass
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Takes the first click, so a skill is picked without the panel having to
/// become key first.
final class ComposerSkillMenuHostingView: NSHostingView<ComposerSkillMenuView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
