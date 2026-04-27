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

    static func highlight(
        _ source: String,
        fileExtension: String,
        fontSize: CGFloat = 12,
        isDark: Bool = isSystemDark,
        theme: Theme = defaultTheme
    ) -> NSAttributedString {
        let font = fontSize == 12 ? theme.font : NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let language = languageName(for: fileExtension)
        let highlighter = isDark ? darkHighlighter : lightHighlighter

        if let highlighter,
           let highlighted = highlighter.highlight(source, as: language, fastRender: true) {
            let result = NSMutableAttributedString(attributedString: highlighted)
            let fullRange = NSRange(location: 0, length: result.length)
            result.addAttribute(.font, value: font, range: fullRange)
            return result
        }

        // Fallback: plain monospaced text
        return NSAttributedString(string: source, attributes: [
            .font: font,
            .foregroundColor: theme.foreground,
        ])
    }

    // MARK: - Language Mapping

    private static func languageName(for ext: String) -> String? {
        switch ext {
        case "swift":                                return "swift"
        case "js", "jsx", "mjs":                     return "javascript"
        case "ts", "tsx":                             return "typescript"
        case "py":                                    return "python"
        case "rb":                                    return "ruby"
        case "rs":                                    return "rust"
        case "go":                                    return "go"
        case "c", "h":                                return "c"
        case "cpp", "hpp", "cc", "cxx":               return "cpp"
        case "m", "mm":                               return "objectivec"
        case "java":                                  return "java"
        case "kt", "kts":                             return "kotlin"
        case "cs":                                    return "csharp"
        case "php":                                   return "php"
        case "sh", "bash", "zsh":                     return "bash"
        case "html", "htm":                           return "xml"
        case "xml", "svg", "plist":                   return "xml"
        case "css":                                   return "css"
        case "scss":                                  return "scss"
        case "less":                                  return "less"
        case "json":                                  return "json"
        case "yml", "yaml":                           return "yaml"
        case "toml":                                  return "ini"
        case "md", "markdown":                        return "markdown"
        case "sql":                                   return "sql"
        case "r", "R":                                return "r"
        case "lua":                                   return "lua"
        case "pl", "pm":                              return "perl"
        case "dart":                                  return "dart"
        case "ex", "exs":                             return "elixir"
        case "erl", "hrl":                            return "erlang"
        case "hs":                                    return "haskell"
        case "scala":                                 return "scala"
        case "tf":                                    return "hcl"
        case "dockerfile", "Dockerfile":              return "dockerfile"
        case "makefile", "Makefile", "mk":            return "makefile"
        case "cmake", "CMakeLists.txt":               return "cmake"
        case "groovy", "gradle":                      return "groovy"
        case "vim":                                   return "vim"
        case "proto":                                 return "protobuf"
        case "graphql", "gql":                        return "graphql"
        default:                                      return nil
        }
    }
}
