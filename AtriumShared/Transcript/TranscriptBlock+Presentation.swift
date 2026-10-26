import Foundation

extension TranscriptBlock {
    /// An SF Symbol for a tool block, so runs of tools read at a glance.
    var symbolName: String {
        switch toolName?.lowercased() {
        case "bash", "command", "shell": "terminal"
        case "read", "view": "doc.text"
        case "edit", "multiedit", "write", "filechange", "notebookedit": "pencil"
        case "grep", "glob", "search", "websearch": "magnifyingglass"
        case "webfetch", "fetch": "globe"
        case "task", "agent": "person.2"
        case "todowrite", "plan": "checklist"
        default: "wrench.and.screwdriver"
        }
    }
}
