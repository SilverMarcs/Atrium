import Foundation

extension HostClient {
    /// Runs one of a project's commands in the checkout the project shows,
    /// restarting it if it's running; `script` runs once in place of its own.
    func run(_ commandID: UUID, in workspaceID: UUID, script: String? = nil) {
        let directory = scope(for: workspaceID).root.filePath
        send(.command(workspaceID: workspaceID, commandID: commandID, action: .run(directory: directory, script: script)))
    }

    /// Runs a one-off script in one of the project's terminals that isn't
    /// running anything, in `directory`.
    /// - Returns: The terminal's command ID.
    func runInTerminal(_ script: String, in directory: String, of workspaceID: UUID) async throws -> UUID {
        guard case .command(let id) = try await request(
            .workspace(id: workspaceID, action: .runInTerminal(directory: directory, script: script))
        ) else { throw HostClientError.unexpectedReply }
        return id
    }

    /// Stops a running command, or runs one that isn't.
    func toggle(_ command: WireCommand, in workspaceID: UUID) {
        if command.isRunning {
            send(.command(workspaceID: workspaceID, commandID: command.id, action: .stop))
        } else {
            run(command.id, in: workspaceID)
        }
    }
}
