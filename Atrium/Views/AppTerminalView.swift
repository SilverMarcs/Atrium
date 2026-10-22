import AppKit
import SwiftTerm

/// Keeps terminal colors and the theme reported to programs in sync.
@MainActor
final class AppTerminalView: LocalProcessTerminalView {
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearance()
    }

    func applyAppearance() {
        let appearance = effectiveAppearance
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        appearance.performAsCurrentDrawingAppearance {
            let foreground = isDark ? NSColor(white: 0.90, alpha: 1) : .labelColor
            let background = NSColor.windowBackgroundColor
            nativeForegroundColor = foreground.usingColorSpace(.sRGB) ?? foreground
            nativeBackgroundColor = (background.usingColorSpace(.sRGB) ?? background).withAlphaComponent(0)
        }
        updateColorScheme(isDark ? .dark : .light)
    }
}
