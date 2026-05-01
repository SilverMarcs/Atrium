import Foundation
import Network
import Observation
import UserNotifications

/// Browses for `_atrium._tcp` Bonjour services, manages a single connection
/// to the chosen host, authenticates with the 6-digit pairing code, and
/// surfaces session state to SwiftUI.
@MainActor
@Observable
final class CompanionClient {
    enum ConnectionState: Equatable {
        case idle
        case browsing
        case connecting(serviceName: String)
        case authenticating
        case connected(serverName: String)
        case failed(String)
    }

    struct DiscoveredHost: Identifiable, Hashable {
        let id: String
        let name: String
        let endpoint: NWEndpoint
        static func == (lhs: DiscoveredHost, rhs: DiscoveredHost) -> Bool { lhs.id == rhs.id }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }

    private static let pairingCodeKey = "companion.pairingCode"
    private static let lastHostNameKey = "companion.lastHostName"
    private static let clientIdKey = "companion.clientId"
    private static let hasConnectedKey = "companion.hasConnectedBefore"
    private static let notifPermAskedKey = "companion.notifPermAsked"
    /// Per-install identifier the iOS client sends to the Mac on every
    /// auth. The server uses this to evict prior connections from this
    /// same device, so reconnects don't accumulate as separate sessions.
    static let clientId: UUID = {
        if let raw = UserDefaults.standard.string(forKey: clientIdKey),
           let uuid = UUID(uuidString: raw) {
            return uuid
        }
        let new = UUID()
        UserDefaults.standard.set(new.uuidString, forKey: clientIdKey)
        return new
    }()
    /// Minimum gap between auto-reconnect attempts. Without this, a
    /// network blip during browse can put us in a tight retry loop.
    private static let autoReconnectCooldown: TimeInterval = 3

    private(set) var state: ConnectionState = .idle
    private(set) var hosts: [DiscoveredHost] = []
    private(set) var workspaces: [WireWorkspace] = []
    /// Provider names the host advertises on `sessionsList`. Empty until
    /// the first list arrives; `NewChatMenu` reads it directly so the
    /// available choices track whatever the Mac currently supports.
    private(set) var availableProviders: [String] = []
    private(set) var activeSession: WireSession?
    private(set) var subscribedSessionId: UUID?
    private(set) var lastError: String?
    /// Most recent source-control snapshot for the workspace iOS is currently
    /// viewing. Populated by the Mac on `gitSubscribe` and after every git
    /// action; cleared when the iOS user leaves the source control screen.
    private(set) var gitStatus: WireGitStatus?
    private(set) var gitWorkspaceId: UUID?
    /// Most recent raw `git diff` text keyed by `<path>|<stage>`. Populated
    /// by the Mac on `gitFileDiffResult`; views read out of this dictionary
    /// rather than holding their own state so navigating back into a diff
    /// shows the prior result instantly.
    private(set) var gitFileDiffs: [String: String] = [:]
    /// Latest commands list for the workspace iOS is currently viewing.
    private(set) var commands: [WireCommand] = []
    private(set) var commandsWorkspaceId: UUID?
    /// Persists across app launches. Drives the root view: while true, the
    /// app stays on the workspaces flow even if the socket is currently
    /// disconnected, so backgrounding doesn't visibly bounce the user back
    /// to the pairing screen. Reset only on user-initiated disconnect or a
    /// rejected auth handshake.
    private(set) var hasConnectedBefore: Bool
    /// True when the client is faking a host connection so the App Store
    /// reviewer (or anyone evaluating the app without a Mac) can exercise
    /// every screen. Drives `send()` to short-circuit into synthetic
    /// responses instead of touching the network. Not persisted — the demo
    /// session ends as soon as the user disconnects.
    private(set) var isDemoMode = false
    /// Buffered demo state used by `CompanionClient+Demo.swift`. Kept on
    /// the main type so the extension can mutate it without exposing
    /// internals through public setters.
    var demoState = CompanionDemoState()
    /// Workspace + session pair to navigate to. Drives both notification
    /// taps and the post-`createChat` push — the root view either appends
    /// `.chat(...)` (when the user is already on the matching workspace)
    /// or rebuilds the path with both stops.
    var pendingDeepLink: PendingDeepLink?

    var isConnectedNow: Bool {
        if case .connected = state { return true }
        return false
    }

    /// True when we've authenticated at least once but the current socket
    /// isn't live — i.e. we're showing stale data while reconnecting.
    var isReconnecting: Bool {
        hasConnectedBefore && !isConnectedNow
    }

    var savedPairingCode: String {
        UserDefaults.standard.string(forKey: Self.pairingCodeKey) ?? ""
    }

    private var browser: NWBrowser?
    private var connection: NWConnection?
    private let frameBuffer = CompanionFrameBuffer()
    private var pendingPairingCode: String?
    private var lastAutoReconnectAt: Date?
    /// True after the user explicitly hits Disconnect — we don't auto-reconnect
    /// from then on, even if scenePhase fires us back to active. Cleared the
    /// next time the user hits Connect.
    private var userInitiatedDisconnect = false

    init() {
        // Optimistic seed: if we paired successfully on a previous launch
        // we want the workspaces UI to come up immediately, then auth
        // either confirms (no flicker) or flips this off (drop to pairing).
        self.hasConnectedBefore = UserDefaults.standard.bool(forKey: Self.hasConnectedKey)
    }

    private func setHasConnectedBefore(_ value: Bool) {
        hasConnectedBefore = value
        UserDefaults.standard.set(value, forKey: Self.hasConnectedKey)
    }

    var savedHostName: String { UserDefaults.standard.string(forKey: Self.lastHostNameKey) ?? "" }

    // MARK: - Discovery

    func startBrowsing() {
        guard !isDemoMode else { return }
        guard browser == nil else { return }
        state = .browsing
        let params = NWParameters()
        params.includePeerToPeer = true
        let descriptor = NWBrowser.Descriptor.bonjour(type: CompanionWire.bonjourServiceType, domain: nil)
        let browser = NWBrowser(for: descriptor, using: params)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in self?.handleBrowse(results: results) }
        }
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                if case .failed(let error) = state {
                    self?.lastError = error.localizedDescription
                }
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stopBrowsing() {
        browser?.cancel()
        browser = nil
    }

    private func handleBrowse(results: Set<NWBrowser.Result>) {
        var found: [DiscoveredHost] = []
        for result in results {
            if case let .service(name, _, _, _) = result.endpoint {
                found.append(DiscoveredHost(id: name, name: name, endpoint: result.endpoint))
            }
        }
        hosts = found.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        attemptAutoConnect()
    }

    /// Connects automatically when we discover the previously-paired host
    /// and have a saved pairing code, unless the user explicitly disconnected
    /// or we're already mid-flight.
    func attemptAutoConnect() {
        guard !isDemoMode else { return }
        guard !userInitiatedDisconnect else { return }
        switch state {
        case .connecting, .authenticating, .connected:
            return
        default:
            break
        }
        if let last = lastAutoReconnectAt, Date().timeIntervalSince(last) < Self.autoReconnectCooldown {
            return
        }
        let savedCode = savedPairingCode
        let savedName = savedHostName
        guard !savedCode.isEmpty, !savedName.isEmpty else { return }
        guard let host = hosts.first(where: { $0.name == savedName }) else { return }
        lastAutoReconnectAt = Date()
        connect(to: host, pairingCode: savedCode)
    }

    /// Called when the app comes back to the foreground. iOS tears down
    /// our socket on background, surfacing as `NWError 53` once we resume.
    /// We just retry — Bonjour browse is still running, so the host is
    /// usually already in `hosts` and the reconnect happens immediately.
    func handleScenePhaseActive() {
        userInitiatedDisconnect = false
        if browser == nil { startBrowsing() }
        attemptAutoConnect()
    }

    // MARK: - Connection

    func connect(to host: DiscoveredHost, pairingCode: String) {
        connection?.cancel()
        connection = nil
        // Intentionally not clearing `workspaces`, `activeSession`, or
        // `subscribedSessionId` here — when this is a transparent
        // reconnect (foregrounding from background), we want the UI to
        // keep showing the last-known data while we re-auth. The host's
        // `sessionsList` and re-issued `sessionSnapshot` overwrite this
        // shortly after auth completes.
        pendingPairingCode = pairingCode
        userInitiatedDisconnect = false
        UserDefaults.standard.set(pairingCode, forKey: Self.pairingCodeKey)
        UserDefaults.standard.set(host.name, forKey: Self.lastHostNameKey)

        state = .connecting(serviceName: host.name)
        let params = NWParameters.tcp
        params.includePeerToPeer = true
        let connection = NWConnection(to: host.endpoint, using: params)
        connection.stateUpdateHandler = { [weak self] cstate in
            Task { @MainActor in self?.handleConnectionState(cstate) }
        }
        connection.start(queue: .main)
        self.connection = connection
        receive()
    }

    func disconnect() {
        userInitiatedDisconnect = true
        connection?.cancel()
        connection = nil
        state = .idle
        workspaces = []
        availableProviders = []
        activeSession = nil
        subscribedSessionId = nil
        setHasConnectedBefore(false)
        isDemoMode = false
        demoState = CompanionDemoState()
    }

    private func handleConnectionState(_ cstate: NWConnection.State) {
        switch cstate {
        case .ready:
            sendAuth()
        case .failed(let error):
            state = .failed(error.localizedDescription)
            lastError = error.localizedDescription
        case .cancelled:
            if case .failed = state { } else { state = .idle }
        default:
            break
        }
    }

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self else { return }
                if let data, !data.isEmpty {
                    self.frameBuffer.append(data)
                    do {
                        while let body = try self.frameBuffer.nextFrame() {
                            let message = try CompanionFraming.decode(body)
                            self.handle(message: message)
                        }
                    } catch {
                        self.state = .failed("Bad data from host: \(error.localizedDescription)")
                        self.connection?.cancel()
                        return
                    }
                }
                if isComplete || error != nil {
                    if case .connected = self.state {
                        self.state = .failed(error?.localizedDescription ?? "Disconnected")
                    }
                    self.connection?.cancel()
                    return
                }
                self.receive()
            }
        }
    }

    private func send(_ message: CompanionMessage) {
        if isDemoMode {
            demoHandle(outgoing: message)
            return
        }
        guard let connection else { return }
        do {
            let data = try CompanionFraming.encode(message)
            connection.send(content: data, completion: .contentProcessed { _ in })
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func sendAuth() {
        state = .authenticating
        var msg = CompanionMessage(kind: .auth)
        msg.token = pendingPairingCode ?? savedPairingCode
        msg.clientId = Self.clientId
        send(msg)
    }

    // MARK: - Inbound

    private func handle(message: CompanionMessage) {
        switch message.kind {
        case .hello:
            // Nothing to do; auth is queued separately when connection opens.
            break
        case .authResult:
            if message.ok == true {
                setHasConnectedBefore(true)
                state = .connected(serverName: message.serverName ?? "Atrium")
                pendingPairingCode = nil
                requestNotificationsIfNeeded()
                requestSessionsList()
                // If the user was viewing a chat when the connection
                // dropped (e.g. iOS killed the socket on background),
                // re-subscribe so they get a fresh snapshot without
                // having to navigate away and back.
                if let id = subscribedSessionId {
                    var sub = CompanionMessage(kind: .subscribe)
                    sub.sessionId = id
                    send(sub)
                }
            } else {
                setHasConnectedBefore(false)
                state = .failed(message.error ?? "Pairing failed")
            }
        case .sessionsList:
            let newWorkspaces = message.workspaces ?? []
            notifyForFinishedSessions(old: workspaces, new: newWorkspaces)
            workspaces = newWorkspaces
            if let providers = message.availableProviders {
                availableProviders = providers
            }
        case .sessionSnapshot:
            if let session = message.session, message.sessionId == subscribedSessionId {
                activeSession = session
            }
        case .sessionUpdate:
            guard let patch = message.patch, message.sessionId == subscribedSessionId,
                  var current = activeSession else { return }
            if let title = patch.title { current.meta.title = title }
            if let date = patch.date { current.meta.date = date }
            if let turnCount = patch.turnCount { current.meta.turnCount = turnCount }
            if let isProcessing = patch.isProcessing { current.meta.isProcessing = isProcessing }
            if let messages = patch.messages { current.messages = messages }
            if let modelLabel = patch.modelLabel { current.modelLabel = modelLabel }
            if let permissionLabel = patch.permissionLabel { current.permissionLabel = permissionLabel }
            if let permissionImage = patch.permissionSystemImage {
                current.permissionSystemImage = permissionImage
            }
            if let usedTokens = patch.usedTokens { current.usedTokens = usedTokens }
            if let contextSize = patch.contextSize { current.contextSize = contextSize }
            if let modelRaw = patch.modelRawValue { current.modelRawValue = modelRaw }
            if let modeRaw = patch.permissionModeRawValue { current.permissionModeRawValue = modeRaw }
            if patch.errorChanged == true { current.error = patch.error }
            activeSession = current
        case .chatCreated:
            if let workspaceId = message.workspaceId, let sessionId = message.sessionId {
                pendingDeepLink = PendingDeepLink(
                    workspaceId: workspaceId,
                    sessionId: sessionId
                )
            }
        case .gitStatus:
            if let wsId = message.workspaceId, wsId == gitWorkspaceId, let status = message.gitStatus {
                gitStatus = status
            }
        case .gitFileDiffResult:
            if let path = message.gitFilePath, let stage = message.gitDiffStage {
                gitFileDiffs[Self.diffKey(path: path, stage: stage)] = message.gitDiffText ?? ""
            }
        case .commandsList:
            if let wsId = message.workspaceId, wsId == commandsWorkspaceId, let cmds = message.commands {
                commands = cmds
            }
        case .error:
            lastError = message.error
        default:
            break
        }
    }

    private static func diffKey(path: String, stage: String) -> String {
        "\(stage)|\(path)"
    }

    // MARK: - Actions

    func requestSessionsList() {
        send(CompanionMessage(kind: .listSessions))
    }

    func subscribe(to sessionId: UUID) {
        if subscribedSessionId == sessionId { return }
        if let prior = subscribedSessionId {
            var unsub = CompanionMessage(kind: .unsubscribe)
            unsub.sessionId = prior
            send(unsub)
        }
        subscribedSessionId = sessionId
        activeSession = nil
        // Optimistically clear the notification badge locally so the row
        // updates immediately; the host will broadcast the same change
        // when it processes the subscribe.
        clearLocalNotification(sessionId: sessionId)
        var sub = CompanionMessage(kind: .subscribe)
        sub.sessionId = sessionId
        send(sub)
    }

    private func clearLocalNotification(sessionId: UUID) {
        for wsIdx in workspaces.indices {
            guard let chatIdx = workspaces[wsIdx].sessions.firstIndex(where: { $0.id == sessionId }) else { continue }
            if workspaces[wsIdx].sessions[chatIdx].hasNotification {
                workspaces[wsIdx].sessions[chatIdx].hasNotification = false
            }
            return
        }
    }

    func unsubscribe() {
        if let id = subscribedSessionId {
            var msg = CompanionMessage(kind: .unsubscribe)
            msg.sessionId = id
            send(msg)
        }
        subscribedSessionId = nil
        activeSession = nil
    }

    // Live Activity / BGContinuedProcessingTask hookup lived here — see
    // commit 3b737b7 if we want it back.
    func sendPrompt(_ text: String) {
        guard let id = subscribedSessionId else { return }
        var msg = CompanionMessage(kind: .sendPrompt)
        msg.sessionId = id
        msg.promptText = text
        send(msg)
    }

    func toggleArchive(sessionId: UUID) {
        var msg = CompanionMessage(kind: .archiveChat)
        msg.sessionId = sessionId
        send(msg)
    }

    func disconnectChat(sessionId: UUID) {
        var msg = CompanionMessage(kind: .disconnectChat)
        msg.sessionId = sessionId
        send(msg)
    }

    func stopChat(sessionId: UUID) {
        var msg = CompanionMessage(kind: .stopChat)
        msg.sessionId = sessionId
        send(msg)
    }

    func deleteChat(sessionId: UUID) {
        var msg = CompanionMessage(kind: .deleteChat)
        msg.sessionId = sessionId
        send(msg)
    }

    /// `providerName == nil` is the "primary action" — Mac falls back to
    /// its `defaultChatMode` AppStorage to pick the provider.
    func createChat(workspaceId: UUID, providerName: String?) {
        var msg = CompanionMessage(kind: .createChat)
        msg.workspaceId = workspaceId
        msg.providerName = providerName
        send(msg)
    }

    func updateScratchpad(workspaceId: UUID, text: String) {
        var msg = CompanionMessage(kind: .updateScratchpad)
        msg.workspaceId = workspaceId
        msg.scratchpadText = text
        send(msg)
    }

    /// Optimistically updates the local snapshot so the picker reflects the
    /// new selection immediately, then asks the host to apply it. The host
    /// echoes the same value back via `sessionUpdate` shortly after, which
    /// is a no-op if it matches.
    func setSessionModel(_ rawValue: String) {
        guard let id = subscribedSessionId else { return }
        if var session = activeSession, session.meta.id == id {
            session.modelRawValue = rawValue
            if let model = session.availableModels.first(where: { $0.rawValue == rawValue }) {
                session.modelLabel = model.name
            }
            activeSession = session
        }
        var msg = CompanionMessage(kind: .setSessionModel)
        msg.sessionId = id
        msg.modelRawValue = rawValue
        send(msg)
    }

    // MARK: - Source control

    func gitSubscribe(workspaceId: UUID) {
        if gitWorkspaceId != workspaceId {
            gitStatus = nil
            gitFileDiffs = [:]
        }
        gitWorkspaceId = workspaceId
        var msg = CompanionMessage(kind: .gitSubscribe)
        msg.workspaceId = workspaceId
        send(msg)
    }

    func gitUnsubscribe() {
        gitWorkspaceId = nil
        gitStatus = nil
        gitFileDiffs = [:]
        send(CompanionMessage(kind: .gitUnsubscribe))
    }

    func gitRefresh(workspaceId: UUID) {
        var msg = CompanionMessage(kind: .gitRefresh)
        msg.workspaceId = workspaceId
        send(msg)
    }

    func gitStage(workspaceId: UUID, files: [WireGitFile]) {
        var msg = CompanionMessage(kind: .gitStage)
        msg.workspaceId = workspaceId
        msg.gitFiles = files
        send(msg)
    }

    func gitUnstage(workspaceId: UUID, files: [WireGitFile]) {
        var msg = CompanionMessage(kind: .gitUnstage)
        msg.workspaceId = workspaceId
        msg.gitFiles = files
        send(msg)
    }

    func gitDiscard(workspaceId: UUID, files: [WireGitFile]) {
        var msg = CompanionMessage(kind: .gitDiscard)
        msg.workspaceId = workspaceId
        msg.gitFiles = files
        send(msg)
    }

    func gitStageAll(workspaceId: UUID) {
        var msg = CompanionMessage(kind: .gitStageAll)
        msg.workspaceId = workspaceId
        send(msg)
    }

    func gitUnstageAll(workspaceId: UUID) {
        var msg = CompanionMessage(kind: .gitUnstageAll)
        msg.workspaceId = workspaceId
        send(msg)
    }

    func gitDiscardAll(workspaceId: UUID) {
        var msg = CompanionMessage(kind: .gitDiscardAll)
        msg.workspaceId = workspaceId
        send(msg)
    }

    func gitCommit(workspaceId: UUID, message commitMessage: String) {
        var msg = CompanionMessage(kind: .gitCommit)
        msg.workspaceId = workspaceId
        msg.gitCommitMessage = commitMessage
        send(msg)
    }

    func gitPush(workspaceId: UUID) {
        var msg = CompanionMessage(kind: .gitPush)
        msg.workspaceId = workspaceId
        send(msg)
    }

    func gitPull(workspaceId: UUID) {
        var msg = CompanionMessage(kind: .gitPull)
        msg.workspaceId = workspaceId
        send(msg)
    }

    func gitFetch(workspaceId: UUID) {
        var msg = CompanionMessage(kind: .gitFetch)
        msg.workspaceId = workspaceId
        send(msg)
    }

    func gitSelectRepository(workspaceId: UUID, path: String) {
        var msg = CompanionMessage(kind: .gitSelectRepository)
        msg.workspaceId = workspaceId
        msg.gitRepositoryPath = path
        send(msg)
    }

    func gitCreateBranch(workspaceId: UUID, name: String) {
        var msg = CompanionMessage(kind: .gitCreateBranch)
        msg.workspaceId = workspaceId
        msg.gitBranch = name
        send(msg)
    }

    func gitRequestFileDiff(workspaceId: UUID, path: String, stage: String) {
        var msg = CompanionMessage(kind: .gitFileDiff)
        msg.workspaceId = workspaceId
        msg.gitFilePath = path
        msg.gitDiffStage = stage
        send(msg)
    }

    func gitFileDiff(path: String, stage: String) -> String? {
        gitFileDiffs[Self.diffKey(path: path, stage: stage)]
    }

    // MARK: - Commands

    func commandsSubscribe(workspaceId: UUID) {
        if commandsWorkspaceId != workspaceId {
            commands = []
        }
        commandsWorkspaceId = workspaceId
        var msg = CompanionMessage(kind: .commandsSubscribe)
        msg.workspaceId = workspaceId
        send(msg)
    }

    func commandsUnsubscribe() {
        commandsWorkspaceId = nil
        commands = []
        send(CompanionMessage(kind: .commandsUnsubscribe))
    }

    func runCommand(workspaceId: UUID, commandId: UUID) {
        var msg = CompanionMessage(kind: .runCommand)
        msg.workspaceId = workspaceId
        msg.commandId = commandId
        send(msg)
    }

    func stopCommand(workspaceId: UUID, commandId: UUID) {
        var msg = CompanionMessage(kind: .stopCommand)
        msg.workspaceId = workspaceId
        msg.commandId = commandId
        send(msg)
    }

    func setSessionPermissionMode(_ rawValue: String) {
        guard let id = subscribedSessionId else { return }
        if var session = activeSession, session.meta.id == id {
            session.permissionModeRawValue = rawValue
            if let mode = session.availableModes.first(where: { $0.rawValue == rawValue }) {
                session.permissionLabel = mode.label
                session.permissionSystemImage = mode.systemImage
            }
            activeSession = session
        }
        var msg = CompanionMessage(kind: .setSessionPermissionMode)
        msg.sessionId = id
        msg.permissionModeRawValue = rawValue
        send(msg)
    }

    // MARK: - Notifications

    private func requestNotificationsIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: Self.notifPermAskedKey) else { return }
        UserDefaults.standard.set(true, forKey: Self.notifPermAskedKey)
        Task { @MainActor in
            _ = try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
        }
    }

    /// Compares the previous and incoming workspace lists; for any chat
    /// that just transitioned from `isProcessing == true` to `false`
    /// while the user is *not* on its detail screen, posts a local
    /// notification. Skips the very first list (no baseline to diff).
    private func notifyForFinishedSessions(old: [WireWorkspace], new: [WireWorkspace]) {
        guard !old.isEmpty else { return }
        var oldProcessing: [UUID: Bool] = [:]
        for ws in old {
            for s in ws.sessions {
                oldProcessing[s.id] = s.isProcessing
            }
        }
        for ws in new {
            for s in ws.sessions {
                guard let was = oldProcessing[s.id], was, !s.isProcessing else { continue }
                if subscribedSessionId == s.id { continue }
                postFinishedNotification(workspaceName: ws.name, session: s)
            }
        }
    }

    private func postFinishedNotification(workspaceName: String, session: WireSessionMeta) {
        let content = UNMutableNotificationContent()
        content.title = workspaceName
        let title = session.title.isEmpty ? "Chat" : session.title
        content.body = "\(title) finished responding"
        content.sound = .default
        // Stash IDs so a tap can deep-link directly to this chat.
        content.userInfo = [
            "workspaceId": session.workspaceId.uuidString,
            "sessionId": session.id.uuidString
        ]
        // Per-session identifier so a fresh "finished" replaces any
        // already-pending alert for that chat instead of stacking.
        let request = UNNotificationRequest(
            identifier: "companion.finished.\(session.id.uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { _ in }
    }

    // MARK: - Demo mode

    /// Bypasses the network and stands up a fake host so the App Store
    /// reviewer (or anyone without the Mac side installed) can navigate
    /// every screen. Sets `hasConnectedBefore` in memory only — we don't
    /// persist it, so a relaunch returns to the pairing screen.
    func enterDemoMode() {
        // Clean up any in-flight network state so the demo doesn't
        // collide with a real reconnect attempt.
        connection?.cancel()
        connection = nil
        browser?.cancel()
        browser = nil
        userInitiatedDisconnect = false
        pendingPairingCode = nil
        lastError = nil

        isDemoMode = true
        demoState = CompanionDemoState()
        state = .connected(serverName: "Demo Mac")
        availableProviders = [CompanionDemo.providerName]
        workspaces = CompanionDemo.seedWorkspaces()
        hasConnectedBefore = true
        // Intentionally not calling setHasConnectedBefore(_:) — demo
        // shouldn't survive a relaunch.
    }

    /// Synthetic transport for demo mode. Translates outgoing wire
    /// messages into local state changes that mimic what a real host
    /// would have echoed back.
    private func demoHandle(outgoing message: CompanionMessage) {
        switch message.kind {
        case .listSessions:
            // Workspaces are seeded on entry; nothing to do.
            break
        case .subscribe:
            guard let id = message.sessionId,
                  let meta = findSessionMeta(id: id) else { return }
            let session = demoState.sessions[id] ?? CompanionDemo.sampleSession(for: meta)
            demoState.sessions[id] = session
            if id == subscribedSessionId {
                activeSession = session
            }
        case .unsubscribe:
            break
        case .sendPrompt:
            guard let id = message.sessionId,
                  let promptText = message.promptText,
                  var session = demoState.sessions[id] else { return }
            let nextTurn = (session.messages.last?.turnIndex ?? -1) + 1
            session.messages.append(CompanionDemo.userMessage(turnIndex: nextTurn, text: promptText))
            session.meta.isProcessing = true
            session.meta.turnCount = session.messages.count
            session.meta.date = Date()
            demoState.sessions[id] = session
            if id == subscribedSessionId { activeSession = session }
            applyMetaChange(in: session.meta)

            let task = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(1.5))
                guard let self, self.isDemoMode,
                      var s = self.demoState.sessions[id] else { return }
                let replyTurn = (s.messages.last?.turnIndex ?? 0) + 1
                s.messages.append(CompanionDemo.assistantReply(turnIndex: replyTurn, to: promptText))
                s.meta.isProcessing = false
                s.meta.turnCount = s.messages.count
                s.meta.date = Date()
                self.demoState.sessions[id] = s
                if id == self.subscribedSessionId { self.activeSession = s }
                self.applyMetaChange(in: s.meta)
            }
            demoState.pendingTasks.append(task)
        case .createChat:
            guard let workspaceId = message.workspaceId,
                  let wsIdx = workspaces.firstIndex(where: { $0.id == workspaceId }) else { return }
            let meta = CompanionDemo.sessionMeta(
                in: workspaceId,
                title: "New chat",
                minutesAgo: 0,
                turnCount: 0,
                isProcessing: false,
                hasNotification: false
            )
            workspaces[wsIdx].sessions.insert(meta, at: 0)
            demoState.sessions[meta.id] = WireSession(
                meta: meta,
                messages: [],
                modelLabel: "Opus 4.7",
                permissionLabel: "Ask",
                permissionSystemImage: "hand.raised",
                usedTokens: 0,
                contextSize: 200_000,
                availableModels: CompanionDemo.availableModels,
                modelRawValue: "claude-opus-4-7",
                availableModes: CompanionDemo.availableModes,
                permissionModeRawValue: "default"
            )
            pendingDeepLink = PendingDeepLink(workspaceId: workspaceId, sessionId: meta.id)
        case .archiveChat:
            guard let id = message.sessionId else { return }
            mutateMeta(id: id) { $0.isArchived.toggle() }
        case .deleteChat:
            guard let id = message.sessionId else { return }
            for wsIdx in workspaces.indices {
                workspaces[wsIdx].sessions.removeAll { $0.id == id }
            }
            demoState.sessions[id] = nil
            if subscribedSessionId == id {
                subscribedSessionId = nil
                activeSession = nil
            }
        case .stopChat, .disconnectChat:
            guard let id = message.sessionId else { return }
            mutateMeta(id: id) { $0.isProcessing = false }
        case .updateScratchpad:
            guard let workspaceId = message.workspaceId,
                  let text = message.scratchpadText,
                  let wsIdx = workspaces.firstIndex(where: { $0.id == workspaceId }) else { return }
            workspaces[wsIdx].scratchpad = text
        case .setSessionModel:
            guard let id = message.sessionId, let raw = message.modelRawValue else { return }
            if var session = demoState.sessions[id] {
                session.modelRawValue = raw
                if let m = session.availableModels.first(where: { $0.rawValue == raw }) {
                    session.modelLabel = m.name
                }
                demoState.sessions[id] = session
                if id == subscribedSessionId { activeSession = session }
            }
        case .setSessionPermissionMode:
            guard let id = message.sessionId, let raw = message.permissionModeRawValue else { return }
            if var session = demoState.sessions[id] {
                session.permissionModeRawValue = raw
                if let m = session.availableModes.first(where: { $0.rawValue == raw }) {
                    session.permissionLabel = m.label
                    session.permissionSystemImage = m.systemImage
                }
                demoState.sessions[id] = session
                if id == subscribedSessionId { activeSession = session }
            }
        default:
            // Git, commands, and any future actions are no-ops in demo.
            // Their screens render an empty/idle state, which is enough
            // for a reviewer to evaluate the UI.
            break
        }
    }

    private func findSessionMeta(id: UUID) -> WireSessionMeta? {
        for ws in workspaces {
            if let s = ws.sessions.first(where: { $0.id == id }) { return s }
        }
        return nil
    }

    private func mutateMeta(id: UUID, _ body: (inout WireSessionMeta) -> Void) {
        for wsIdx in workspaces.indices {
            guard let chatIdx = workspaces[wsIdx].sessions.firstIndex(where: { $0.id == id }) else { continue }
            body(&workspaces[wsIdx].sessions[chatIdx])
            let updated = workspaces[wsIdx].sessions[chatIdx]
            if var session = demoState.sessions[id] {
                session.meta = updated
                demoState.sessions[id] = session
                if id == subscribedSessionId { activeSession = session }
            }
            return
        }
    }

    private func applyMetaChange(in meta: WireSessionMeta) {
        for wsIdx in workspaces.indices {
            if let chatIdx = workspaces[wsIdx].sessions.firstIndex(where: { $0.id == meta.id }) {
                workspaces[wsIdx].sessions[chatIdx] = meta
                return
            }
        }
    }
}
