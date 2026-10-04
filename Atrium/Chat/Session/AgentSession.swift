import Foundation
import Observation

@Observable
@MainActor
final class AgentSession {
    private(set) var state: AgentSessionState = .disconnected
    private(set) var sessionID: String?
    private(set) var models: [AgentModel] = []
    private(set) var permissionModes: [PermissionMode] = []
    private(set) var permissions: [PermissionPrompt] = []
    private(set) var questions: [QuestionRequest] = []
    private(set) var isSubmittingSteering = false
    private(set) var activeTurnToken: UUID?
    @ObservationIgnored private var steering: Task<Void, Never>?
    var model = ""
    var reasoningLevel = ""
    var permissionMode: String = ""
    var usedTokens = 0
    var contextSize = 0
    var plan: [PlanEntry] = []
    var availableCommands: [AvailableCommand] = []
    var onEvent: ((AgentEvent) -> Void)?
    var onConnected: (() -> Void)?
    var onFailure: (() -> Void)?
    @ObservationIgnored private var backend: (any AgentBackend)?
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var deadline: Task<Void, Never>?
    @ObservationIgnored private var activeModelID: String?
    @ObservationIgnored private var provider: AgentProvider = .codex
    @ObservationIgnored private var directory = ""

    var isConnected: Bool { state == .ready || isProcessing }
    var isConnecting: Bool { state == .connecting }
    var isProcessing: Bool { state == .running || state == .stopping }
    var canSteer: Bool { state == .running && activeTurnToken != nil && !isSubmittingSteering && backend?.canSteer == true }
    var pendingQuestion: QuestionRequest? { questions.first }
    var pendingPermission: PermissionPrompt? { permissions.first }
    var error: String? { if case .failed(let message) = state { return message }; return nil }
    var selectedModel: AgentModel? { (models.isEmpty ? ModelCatalog.shared.models(for: provider) : models).first { $0.rawValue == model } }
    var reasoningLevels: [ReasoningLevel] { selectedModel?.reasoningLevels ?? [] }

    func connect(provider: AgentProvider, directory: String, sessionID: String?) {
        guard !isConnected, !isConnecting else { return }
        self.provider = provider
        self.directory = directory
        self.sessionID = sessionID
        state = .connecting
        let adapter = AgentBackendFactory.make(provider)
        backend = adapter
        adapter.onEvent = { [weak self, weak adapter] event in
            guard let self, let adapter, self.backend === adapter else { return }
            receive(event)
        }
        adapter.onFailure = { [weak self, weak adapter] error in
            guard let self, let adapter, self.backend === adapter else { return }
            fail(error)
        }
        deadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) }
            catch { return }
            self?.fail(AgentError(message: "Agent startup timed out after 30 seconds"))
        }
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                let connection = try await adapter.connect(settings)
                guard backend === adapter else { return }
                deadline?.cancel()
                deadline = nil
                self.sessionID = connection.sessionID
                models = connection.catalog.models
                permissionModes = connection.catalog.permissionModes
                permissionMode = connection.permissionMode
                ModelCatalog.shared.ingest(connection.catalog, provider: provider)
                model = connection.model
                reasoningLevel = connection.reasoningLevel
                state = .ready
                onConnected?()
            } catch {
                guard backend === adapter else { return }
                fail(error)
            }
        }
    }

    func send(_ input: AgentInput) {
        guard state == .ready, let adapter = backend else { return }
        if !input.imagePaths.isEmpty, selectedModel?.supportsImages != true {
            fail(AgentError(message: "The selected model does not advertise image input support"))
            return
        }
        let turnSettings = settings
        activeModelID = turnSettings.model
        state = .running
        operation = Task { [weak self] in
            guard let self else { return }
            do { try await adapter.send(input, settings: turnSettings) }
            catch {
                guard backend === adapter else { return }
                fail(error)
            }
        }
    }

    func steer(_ input: AgentInput) {
        guard canSteer, let adapter = backend else { return }
        if !input.imagePaths.isEmpty, models.first(where: { $0.rawValue == activeModelID })?.supportsImages != true {
            fail(AgentError(message: "The selected model does not advertise image input support"))
            return
        }
        isSubmittingSteering = true
        steering = Task { [weak self] in
            guard let self else { return }
            defer { if backend === adapter { isSubmittingSteering = false } }
            do { try await adapter.steer(input) }
            catch {
                guard backend === adapter else { return }
                fail(error)
            }
        }
    }

    func stopStreaming() {
        guard state == .running, let adapter = backend else { return }
        state = .stopping
        deadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(10)) }
            catch { return }
            self?.fail(AgentError(message: "Agent did not stop within 10 seconds"))
        }
        Task { [weak self] in
            do { try await adapter.stop() }
            catch {
                guard let self, backend === adapter else { return }
                fail(error)
            }
        }
    }

    func applyModel(_ value: String) {
        let available = models.isEmpty ? ModelCatalog.shared.models(for: provider) : models
        guard let selected = available.first(where: { $0.rawValue == value }) else { return }
        model = value
        if !selected.reasoningLevels.contains(where: { $0.id == reasoningLevel }) { reasoningLevel = selected.defaultReasoningLevel }
    }

    func applyReasoningLevel(_ value: String) {
        guard reasoningLevels.contains(where: { $0.id == value }) else { return }
        reasoningLevel = value
    }

    func applyPermissionMode(_ value: String) {
        guard permissionModes.contains(where: { $0.rawValue == value }) else { return }
        permissionMode = value
    }

    func disconnect() {
        release()
        state = .disconnected
        onFailure?()
    }

    private var settings: AgentSettings {
        AgentSettings(directory: directory, sessionID: sessionID, model: model, reasoningLevel: reasoningLevel, permissionMode: permissionMode)
    }

    private func receive(_ event: AgentEvent) {
        switch event {
        case .session(let id, _): sessionID = id
        case .permission(let prompt): permissions.append(prompt)
        case .permissionResolved(let id): permissions.removeAll { $0.id == id }
        case .question(let request): questions.append(request)
        case .questionResolved(let id): questions.removeAll { $0.id == id }
        case .turnStarted: activeTurnToken = UUID(); if state != .stopping { state = .running }
        case .turnFinished: activeTurnToken = nil; activeModelID = nil; deadline?.cancel(); deadline = nil; state = .ready; permissions.removeAll(); questions.removeAll { $0.requiresActiveTurn }
        case .usage(let used, let capacity): usedTokens = used; contextSize = capacity
        case .plan(let entries): plan = entries
        case .model(let value):
            if model == activeModelID { model = value }
            activeModelID = value
        case .userReply, .text, .thought, .tool: break
        }
        onEvent?(event)
    }

    func fail(_ error: Error) {
        let message = error.localizedDescription
        print("[Agent] \(message)")
        release()
        state = .failed(message)
        onFailure?()
    }

    private func release() {
        deadline?.cancel()
        deadline = nil
        operation?.cancel()
        operation = nil
        steering?.cancel()
        steering = nil
        isSubmittingSteering = false
        activeTurnToken = nil
        activeModelID = nil
        questions.removeAll()
        let adapter = backend
        backend = nil
        adapter?.close()
        permissions.removeAll()
    }
}
