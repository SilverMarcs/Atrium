import Foundation
import Network

extension ClientHandler {
    func commandsSubscribe(workspaceId: UUID) {
        commandsSubscription?.invalidate()
        guard let store, let workspace = store.workspaces.first(where: { $0.id == workspaceId }) else {
            sendError("workspace not found")
            return
        }
        sendCommandsList(workspace: workspace)
        let sub = CommandsSubscription(workspace: workspace) { [weak self, weak workspace] in
            guard let self, let workspace else { return }
            self.sendCommandsList(workspace: workspace)
        }
        sub.start()
        commandsSubscription = sub
    }

    func sendCommandsList(workspace: Workspace) {
        let cmds = workspace.commands.map {
            WireCommand(
                id: $0.id,
                title: $0.title,
                script: $0.runScript,
                isRunning: $0.hasChildProcess,
                isDefault: $0.isDefault
            )
        }
        var msg = CompanionMessage(kind: .commandsList)
        msg.workspaceId = workspace.id
        msg.commands = cmds
        send(msg)
    }

    func runCommand(workspaceId: UUID, commandId: UUID) {
        guard let store, let workspace = store.workspaces.first(where: { $0.id == workspaceId }) else {
            sendError("workspace not found")
            return
        }
        guard let command = workspace.commands.first(where: { $0.id == commandId }) else {
            sendError("command not found")
            return
        }
        workspace.runCommand(command)
    }

    func stopCommand(workspaceId: UUID, commandId: UUID) {
        guard let store, let workspace = store.workspaces.first(where: { $0.id == workspaceId }) else {
            sendError("workspace not found")
            return
        }
        guard let command = workspace.commands.first(where: { $0.id == commandId }) else {
            sendError("command not found")
            return
        }
        command.interrupt()
    }}
