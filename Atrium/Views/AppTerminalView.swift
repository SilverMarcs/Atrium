import AppKit
import SwiftTerm

/// Keeps terminal colors and the theme reported to programs in sync.
@MainActor
final class AppTerminalView: LocalProcessTerminalView {
    private var appliedIsDark: Bool?

    /// Use the host's scheme even before this retained view belongs to a window.
    func applyAppearance(isDark: Bool) {
        guard appliedIsDark != isDark,
              let appearance = NSAppearance(named: isDark ? .darkAqua : .aqua) else { return }
        appearance.performAsCurrentDrawingAppearance {
            let foreground = isDark ? NSColor(white: 0.90, alpha: 1) : .labelColor
            let background = NSColor.windowBackgroundColor
            nativeForegroundColor = foreground.usingColorSpace(.sRGB) ?? foreground
            nativeBackgroundColor = (background.usingColorSpace(.sRGB) ?? background).withAlphaComponent(0)
        }
        updateColorScheme(isDark ? .dark : .light)
        appliedIsDark = isDark
    }
}
