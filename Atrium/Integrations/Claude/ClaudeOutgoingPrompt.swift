import Foundation

struct ClaudeOutgoingPrompt {
    let id = UUID()
    let wireText: String
    let displayText: String
    let images: [Data]
}
