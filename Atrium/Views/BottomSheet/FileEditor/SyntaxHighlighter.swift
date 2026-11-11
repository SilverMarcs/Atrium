import AppKit
import Highlightr

/// Syntax highlighter backed by Highlightr (highlight.js).
///
/// Uses separate instances for light and dark themes so callers can switch
/// without mutating shared state mid-highlight. Callers pass `isDark` based on
/// the current appearance; views should re-invoke `highlight` when the
/// color scheme changes so existing buffers pick up the new palette.
enum SyntaxHighlighter {

    nonisolated(unsafe) private static let darkHighlighter: Highlightr? = {
        let h = Highlightr()
        h?.setTheme(to: "atom-one-dark")
        return h
    }()

    nonisolated(unsafe) private static let lightHighlighter: Highlightr? = {
        let h = Highlightr()
        h?.setTheme(to: "atom-one-light")
        return h
    }()

    struct Theme {
        var keyword = NSColor.systemPink
        var string = NSColor.systemRed
        var comment = NSColor.systemGreen
        var number = NSColor.systemBlue
        var type = NSColor.systemTeal
        var preprocessor = NSColor.systemOrange
        var background = NSColor.textBackgroundColor
        var foreground = NSColor.labelColor
        var font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    }

    static let defaultTheme = Theme()

    /// Resolved from the running app's effective appearance. Views that know
    /// their own appearance (SwiftUI `colorScheme`, NSView `effectiveAppearance`)
    /// should pass `isDark` explicitly rather than relying on this fallback.
    static var isSystemDark: Bool {
        NSApplication.shared.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    // MARK: - Public

    nonisolated static func highlight(
        _ source: String,
        fileExtension: String,
        fontSize: CGFloat = 12,
        isDark: Bool = isSystemDark,
        theme: Theme = defaultTheme
    ) -> NSAttributedString {
        let font = fontSize == 12 ? theme.font : NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)

        // Skip Highlightr when we don't know the language. Auto-detect scores
        // every grammar against the source — O(grammars × length) and brutal
        // on large files like project.pbxproj. Plain text is the right call.
        guard let language = languageName(for: fileExtension) else {
            return plain(source, font: font, theme: theme)
        }

        let highlighter = isDark ? darkHighlighter : lightHighlighter
        guard let highlighter,
              let highlighted = highlighter.highlight(source, as: language, fastRender: true) else {
            return plain(source, font: font, theme: theme)
        }

        let result = NSMutableAttributedString(attributedString: highlighted)
        result.addAttribute(.font, value: font, range: NSRange(location: 0, length: result.length))
        return result
    }

    /// Off-main-thread variant — callers should use this for any user-visible
    /// editor or diff render. Highlightr passes can take seconds on large
    /// buffers and would otherwise freeze the UI.
    static func highlightAsync(
        _ source: String,
        fileExtension: String,
        fontSize: CGFloat,
        isDark: Bool
    ) async -> NSAttributedString {
        await Task.detached(priority: .userInitiated) {
            highlight(source, fileExtension: fileExtension, fontSize: fontSize, isDark: isDark)
        }.value
    }

    /// Unstyled monospaced fallback — used as the immediate paint while an
    /// async highlight pass runs in the background.
    nonisolated static func plain(
        _ source: String,
        fontSize: CGFloat = 12,
        theme: Theme = defaultTheme
    ) -> NSAttributedString {
        let font = fontSize == 12 ? theme.font : NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        return plain(source, font: font, theme: theme)
    }

    private nonisolated static func plain(_ source: String, font: NSFont, theme: Theme) -> NSAttributedString {
        NSAttributedString(string: source, attributes: [
            .font: font,
            .foregroundColor: theme.foreground,
        ])
    }

    // MARK: - Language Mapping

    private static func languageName(for ext: String) -> String? {
        CodeLanguage.highlightName(forExtension: ext)
    }
}
