import Foundation
import Observation

@Observable
@MainActor
final class PermissionPrompt: Identifiable {
    let id = UUID()
    let toolName: String
    let options: [PermissionOption]
    private var reply: ((String?) -> Void)?

    init(toolName: String, options: [PermissionOption], reply: @escaping (String?) -> Void) {
        self.toolName = toolName
        self.options = options
        self.reply = reply
    }

    func respond(optionId: String?) {
        let action = reply
        reply = nil
        action?(optionId)
    }
}
