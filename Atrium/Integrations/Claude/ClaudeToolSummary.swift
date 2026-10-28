import Foundation

/// Formats tool inputs from live Claude hook events.
nonisolated enum ClaudeToolSummary {
    /// The inputs that best describe a tool not summarized by name, in order.
    private static let summaryKeys = ["description", "summary", "prompt", "message", "query", "command", "url", "file_path", "path"]

    static func summary(of tool: String, input: [String: Any]) -> String {
        func string(_ key: String) -> String? { (input[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        let value: String? = switch tool {
        case "Bash": string("command")
        case "Read", "Write", "Edit", "MultiEdit", "NotebookEdit":
            string("file_path").map { ($0 as NSString).lastPathComponent }
        case "Grep", "Glob": string("pattern")
        case "WebFetch": string("url")
        case "WebSearch": string("query")
        case "Task", "Agent": string("description")
        case "TodoWrite": "Updated the plan"
        // A dictionary's order differs between reads, and a summary that changed
        // would resend the message to the companion on every reload.
        default: (summaryKeys + input.keys.sorted()).lazy.compactMap(string).first
        }
        let line = value?.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? tool
        return String(line.prefix(200))
    }
}
