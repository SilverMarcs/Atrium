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
        return highlight(source, languageHint: fileExtension, font: font, isDark: isDark, theme: theme)
    }

    /// Highlight using a markdown fence language hint (e.g. ```` ```swift ````,
    /// ```` ```python ````). Accepts both file extensions ("py") and full
    /// language names ("python"); unknown hints fall back to plain monospace.
    nonisolated static func highlight(
        _ source: String,
        languageHint: String?,
        fontSize: CGFloat,
        isDark: Bool,
        theme: Theme = defaultTheme
    ) -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        return highlight(source, languageHint: languageHint, font: font, isDark: isDark, theme: theme)
    }

    private nonisolated static func highlight(
        _ source: String,
        languageHint: String?,
        font: NSFont,
        isDark: Bool,
        theme: Theme
    ) -> NSAttributedString {
        // Skip Highlightr when we don't know the language. Auto-detect scores
        // every grammar against the source — O(grammars × length) and brutal
        // on large files like project.pbxproj. Plain text is the right call.
        guard let hint = languageHint?.lowercased(),
              let language = languageName(forHint: hint) else {
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

    /// Maps a lowercased file extension or markdown fence hint
    /// (e.g. "py", "python", "swift", "c++") to a highlight.js language name.
    private static func languageName(forHint hint: String) -> String? {
        switch hint {
        case "swift":                                          return "swift"
        case "js", "javascript", "jsx", "mjs", "node":         return "javascript"
        case "ts", "typescript", "tsx":                        return "typescript"
        case "py", "python", "python3":                        return "python"
        case "rb", "ruby":                                     return "ruby"
        case "rs", "rust":                                     return "rust"
        case "go", "golang":                                   return "go"
        case "c", "h":                                         return "c"
        case "cpp", "c++", "cxx", "cc", "hpp":                 return "cpp"
        case "objc", "objectivec", "objective-c", "m", "mm":   return "objectivec"
        case "java":                                           return "java"
        case "kt", "kotlin", "kts":                            return "kotlin"
        case "cs", "csharp", "c#":                             return "csharp"
        case "php":                                            return "php"
        case "sh", "bash", "shell", "shellscript", "zsh", "console": return "bash"
        case "html", "htm":                                    return "xml"
        case "xml", "svg", "plist":                            return "xml"
        case "css":                                            return "css"
        case "scss", "sass":                                   return "scss"
        case "less":                                           return "less"
        case "json":                                           return "json"
        case "yml", "yaml":                                    return "yaml"
        case "toml", "ini":                                    return "ini"
        case "md", "markdown":                                 return "markdown"
        case "sql":                                            return "sql"
        case "r":                                              return "r"
        case "lua":                                            return "lua"
        case "pl", "perl", "pm":                               return "perl"
        case "dart":                                           return "dart"
        case "ex", "elixir", "exs":                            return "elixir"
        case "erl", "erlang", "hrl":                           return "erlang"
        case "hs", "haskell":                                  return "haskell"
        case "scala":                                          return "scala"
        case "tf", "terraform", "hcl":                         return "hcl"
        case "dockerfile", "docker":                           return "dockerfile"
        case "makefile", "make", "mk":                         return "makefile"
        case "cmake":                                          return "cmake"
        case "groovy", "gradle":                               return "groovy"
        case "vim", "viml":                                    return "vim"
        case "proto", "protobuf":                              return "protobuf"
        case "graphql", "gql":                                 return "graphql"
        case "diff", "patch":                                  return "diff"
        default:                                               return nil
        }
    }
}
