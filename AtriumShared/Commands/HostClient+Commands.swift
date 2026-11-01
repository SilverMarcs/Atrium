import AtriumClient
import AtriumProtocol
import Foundation

extension HostClient {
    /// Runs one of a project's commands in the checkout the project shows,
    /// restarting it if it's running; `script` runs once in place of its own.
    func run(_ commandID: UUID, in workspaceID: UUID, script: String? = nil) {
        let directory = scope(for: workspaceID).root.filePath
        send(.command(workspaceID: workspaceID, commandID: commandID, action: .run(directory: directory, script: script)))
    }
}
