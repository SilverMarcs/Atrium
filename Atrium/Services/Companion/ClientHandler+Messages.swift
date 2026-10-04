import Foundation
import Network

extension ClientHandler {
    func handle(_ message: CompanionMessage) {
        switch message.kind {
        case .auth:
            handleAuth(token: message.token ?? "", clientId: message.clientId)
        case .listSessions:
            guard isAuthenticated else { sendError("not authenticated"); return }
            sendSessionsList()
        case .subscribe:
            guard isAuthenticated else { sendError("not authenticated"); return }
            if let id = message.sessionId { subscribe(to: id) }
        case .unsubscribe:
            subscription?.invalidate()
            subscription = nil
        case .sendPrompt:
            guard isAuthenticated else { sendError("not authenticated"); return }
            if let id = message.sessionId, let text = message.promptText {
                sendPrompt(sessionId: id, text: text)
            }
        case .steerPrompt:
            guard isAuthenticated else { sendError("not authenticated"); return }
            if let id = message.sessionId, let text = message.promptText, let token = message.expectedTurnToken,
               let store, let chat = WireSnapshotter.findChat(id: id, in: store) {
                guard chat.session.activeTurnToken == token,
                      chat.sendMessage(text, steeringOnly: true) else { sendError("The active response can no longer be steered"); return }
            }
        case .answerQuestions:
            guard isAuthenticated else { sendError("not authenticated"); return }
            if let id = message.sessionId, let requestId = message.questionRequestId, let answers = message.questionAnswers,
               let store, let chat = WireSnapshotter.findChat(id: id, in: store) {
                guard let request = chat.session.questions.first(where: { $0.id == requestId }), request.respond(answers) else {
                    sendError("Question request expired or answers are invalid")
                    return
                }
            }
        case .archiveChat:
            guard isAuthenticated else { sendError("not authenticated"); return }
            if let id = message.sessionId { toggleArchive(sessionId: id) }
        case .disconnectChat:
            guard isAuthenticated else { sendError("not authenticated"); return }
            if let id = message.sessionId { disconnectChat(sessionId: id) }
        case .deleteChat:
            guard isAuthenticated else { sendError("not authenticated"); return }
            if let id = message.sessionId { deleteChat(sessionId: id) }
        case .createChat:
            guard isAuthenticated else { sendError("not authenticated"); return }
            if let wsId = message.workspaceId {
                createChat(workspaceId: wsId, providerName: message.providerName)
            }
        case .updateScratchpad:
            guard isAuthenticated else { sendError("not authenticated"); return }
            if let wsId = message.workspaceId, let text = message.scratchpadText {
                updateScratchpad(workspaceId: wsId, text: text)
            }
        case .stopChat:
            guard isAuthenticated else { sendError("not authenticated"); return }
            if let id = message.sessionId { stopChat(sessionId: id) }
        case .setSessionModel:
            guard isAuthenticated else { sendError("not authenticated"); return }
            if let id = message.sessionId, let raw = message.modelRawValue {
                setSessionModel(sessionId: id, modelRawValue: raw)
            }
        case .setSessionReasoningLevel:
            guard isAuthenticated else { sendError("not authenticated"); return }
            if let id = message.sessionId, let value = message.reasoningLevel,
               let store, let chat = WireSnapshotter.findChat(id: id, in: store) {
                guard chat.session.reasoningLevels.contains(where: { $0.id == value }) else {
                    sendError("invalid reasoning level")
                    return
                }
                chat.selectReasoningLevel(value)
            }
        case .setSessionPermissionMode:
            guard isAuthenticated else { sendError("not authenticated"); return }
            if let id = message.sessionId, let raw = message.permissionModeRawValue {
                setSessionPermissionMode(sessionId: id, modeRawValue: raw)
            }
        case .gitSubscribe:
            guard isAuthenticated else { sendError("not authenticated"); return }
            if let wsId = message.workspaceId { gitSubscribe(workspaceId: wsId) }
        case .gitUnsubscribe:
            gitSubscription?.invalidate()
            gitSubscription = nil
        case .gitRefresh:
            guard isAuthenticated else { sendError("not authenticated"); return }
            if let wsId = message.workspaceId { sendGitStatus(workspaceId: wsId) }
        case .gitStage:
            guard isAuthenticated else { sendError("not authenticated"); return }
            if let wsId = message.workspaceId, let files = message.gitFiles {
                performGitAction(workspaceId: wsId) { snap in
                    try await GitRepository.shared.stage(paths: files.map(\.path), at: snap.repositoryRootURL)
                }
            }
        case .gitUnstage:
            guard isAuthenticated else { sendError("not authenticated"); return }
            if let wsId = message.workspaceId, let files = message.gitFiles {
                performGitAction(workspaceId: wsId) { snap in
                    try await GitRepository.shared.unstage(paths: files.map(\.path), at: snap.repositoryRootURL)
                }
            }
        case .gitDiscard:
            guard isAuthenticated else { sendError("not authenticated"); return }
            if let wsId = message.workspaceId, let files = message.gitFiles {
                performGitAction(workspaceId: wsId) { snap in
                    let tracked = files.filter { $0.status != GitChangeKind.untracked.rawValue }.map(\.path)
                    let untracked = files.filter { $0.status == GitChangeKind.untracked.rawValue }.map(\.path)
                    try await GitRepository.shared.discardChanges(
                        trackedPaths: tracked,
                        untrackedPaths: untracked,
                        at: snap.repositoryRootURL
                    )
                }
            }
        case .gitStageAll:
            guard isAuthenticated else { sendError("not authenticated"); return }
            if let wsId = message.workspaceId {
                performGitAction(workspaceId: wsId) { snap in
                    let paths = snap.unstagedFiles.map(\.repositoryRelativePath)
                    guard !paths.isEmpty else { return }
                    try await GitRepository.shared.stage(paths: paths, at: snap.repositoryRootURL)
                }
            }
        case .gitUnstageAll:
            guard isAuthenticated else { sendError("not authenticated"); return }
            if let wsId = message.workspaceId {
                performGitAction(workspaceId: wsId) { snap in
                    let paths = snap.stagedFiles.map(\.repositoryRelativePath)
                    guard !paths.isEmpty else { return }
                    try await GitRepository.shared.unstage(paths: paths, at: snap.repositoryRootURL)
                }
            }
        case .gitDiscardAll:
            guard isAuthenticated else { sendError("not authenticated"); return }
            if let wsId = message.workspaceId {
                performGitAction(workspaceId: wsId) { snap in
                    try await GitRepository.shared.discardAllChanges(at: snap.repositoryRootURL)
                }
            }
        case .gitCommit:
            guard isAuthenticated else { sendError("not authenticated"); return }
            if let wsId = message.workspaceId, let msg = message.gitCommitMessage {
                performGitAction(workspaceId: wsId) { snap in
                    let text = msg.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return }
                    try await GitRepository.shared.commit(message: text, at: snap.repositoryRootURL)
                }
            }
        case .gitPush:
            guard isAuthenticated else { sendError("not authenticated"); return }
            if let wsId = message.workspaceId {
                performGitAction(workspaceId: wsId) { snap in
                    if snap.hasTrackingBranch {
                        try await GitRepository.shared.push(at: snap.repositoryRootURL)
                    } else if let branch = snap.branchName {
                        try await GitRepository.shared.pushSetUpstream(branch: branch, at: snap.repositoryRootURL)
                    }
                }
            }
        case .gitPull:
            guard isAuthenticated else { sendError("not authenticated"); return }
            if let wsId = message.workspaceId {
                performGitAction(workspaceId: wsId) { snap in
                    _ = try await GitRepository.shared.pullPreservingChanges(at: snap.repositoryRootURL)
                }
            }
        case .gitFetch:
            guard isAuthenticated else { sendError("not authenticated"); return }
            if let wsId = message.workspaceId {
                performGitAction(workspaceId: wsId) { snap in
                    try await GitRepository.shared.fetch(at: snap.repositoryRootURL)
                }
            }
        case .gitSwitchBranch:
            guard isAuthenticated else { sendError("not authenticated"); return }
            if let wsId = message.workspaceId, let branch = message.gitBranch {
                performGitAction(workspaceId: wsId) { snap in
                    try await GitRepository.shared.switchBranch(to: branch, at: snap.repositoryRootURL)
                }
            }
        case .gitCreateBranch:
            guard isAuthenticated else { sendError("not authenticated"); return }
            if let wsId = message.workspaceId, let name = message.gitBranch {
                performGitAction(workspaceId: wsId) { snap in
                    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    try await GitRepository.shared.createBranch(named: trimmed, at: snap.repositoryRootURL)
                }
            }
        case .gitSelectRepository:
            guard isAuthenticated else { sendError("not authenticated"); return }
            if let wsId = message.workspaceId, let path = message.gitRepositoryPath {
                selectedGitRepoPaths[wsId] = URL(fileURLWithPath: path)
                sendGitStatus(workspaceId: wsId)
            }
        case .gitFileDiff:
            guard isAuthenticated else { sendError("not authenticated"); return }
            if let wsId = message.workspaceId,
               let path = message.gitFilePath,
               let stage = message.gitDiffStage {
                sendFileDiff(workspaceId: wsId, path: path, stage: stage)
            }
        case .commandsSubscribe:
            guard isAuthenticated else { sendError("not authenticated"); return }
            if let wsId = message.workspaceId { commandsSubscribe(workspaceId: wsId) }
        case .commandsUnsubscribe:
            commandsSubscription?.invalidate()
            commandsSubscription = nil
        case .runCommand:
            guard isAuthenticated else { sendError("not authenticated"); return }
            if let wsId = message.workspaceId, let cmdId = message.commandId {
                runCommand(workspaceId: wsId, commandId: cmdId)
            }
        case .stopCommand:
            guard isAuthenticated else { sendError("not authenticated"); return }
            if let wsId = message.workspaceId, let cmdId = message.commandId {
                stopCommand(workspaceId: wsId, commandId: cmdId)
            }
        default:
            break
        }
    }

}
