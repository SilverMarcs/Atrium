import Foundation

/// The highlight.js language Highlightr colours a file as. Unknown files stay
/// plain: Highlightr's auto-detection scores every grammar against the whole
/// text, which is brutal on large files like project.pbxproj.
nonisolated enum CodeLanguage {
    /// The language for a file by its name: its extension, or the whole name
    /// for files that have none, like Makefile.
    static func highlightName(forFileNamed name: String) -> String? {
        let fileExtension = URL(filePath: name).pathExtension
        return highlightName(forExtension: (fileExtension.isEmpty ? name : fileExtension).lowercased())
    }

    /// The language for a lowercased file extension.
    static func highlightName(forExtension fileExtension: String) -> String? {
        switch fileExtension {
        case "swift": "swift"
        case "js", "jsx", "mjs": "javascript"
        case "ts", "tsx": "typescript"
        case "py": "python"
        case "rb": "ruby"
        case "rs": "rust"
        case "go": "go"
        case "c", "h": "c"
        case "cpp", "hpp", "cc", "cxx": "cpp"
        case "m", "mm": "objectivec"
        case "java": "java"
        case "kt", "kts": "kotlin"
        case "cs": "csharp"
        case "php": "php"
        case "sh", "bash", "zsh": "bash"
        case "html", "htm", "xml", "svg", "plist": "xml"
        case "css": "css"
        case "scss": "scss"
        case "less": "less"
        case "json": "json"
        case "yml", "yaml": "yaml"
        case "toml": "ini"
        case "md", "markdown": "markdown"
        case "sql": "sql"
        case "r": "r"
        case "lua": "lua"
        case "pl", "pm": "perl"
        case "dart": "dart"
        case "ex", "exs": "elixir"
        case "erl", "hrl": "erlang"
        case "hs": "haskell"
        case "scala": "scala"
        case "tf": "hcl"
        case "dockerfile": "dockerfile"
        case "makefile", "mk": "makefile"
        case "cmake": "cmake"
        case "groovy", "gradle": "groovy"
        case "vim": "vim"
        case "proto": "protobuf"
        case "graphql", "gql": "graphql"
        default: nil
        }
    }
}
