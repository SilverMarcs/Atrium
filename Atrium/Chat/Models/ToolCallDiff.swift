import Foundation

struct ToolCallDiff: Sendable {
    let path: String
    var oldText: String?
    var newText: String = ""
    var patch: String?
}
