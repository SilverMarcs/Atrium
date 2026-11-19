import AppKit
import SwiftUI

/// The window behind the Mac skill menu: borderless, in the menu material,
/// and never key, so the editor keeps the keyboard while the menu is up and
/// typing carries on narrowing it.
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

        let material = NSVisualEffectView()
        material.material = .menu
        material.blendingMode = .behindWindow
        material.state = .active
        material.maskImage = Self.mask(cornerRadius: ComposerSkillMenuMetrics.cornerRadius)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        material.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: material.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: material.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: material.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: material.bottomAnchor),
        ])
        contentView = material
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// A rounded rect that stretches to any size, keeping its corners.
    private static func mask(cornerRadius: CGFloat) -> NSImage {
        let edge = cornerRadius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: cornerRadius, left: cornerRadius, bottom: cornerRadius, right: cornerRadius)
        image.resizingMode = .stretch
        return image
    }
}

/// Takes the first click, so a skill is picked without the panel having to
/// become key first.
final class ComposerSkillMenuHostingView: NSHostingView<ComposerSkillMenuView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
