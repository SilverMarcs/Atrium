import Foundation

/// Provider boundary. Implementations own connections, SDKs, wire formats, and CLI options.
/// Events and snapshots use only the shared models consumed by AgentIntegrationStore.
@MainActor
protocol AgentProviderAdapter: AnyObject {
    var provider: AgentProvider { get }
    var capabilities: AgentCapabilities { get }
    var onEvent: ((AgentEvent) -> Void)? { get set }

    /// Opens the provider connection, independently of any terminal attachment.
    func openConversation(_ thread: AgentThread) async throws
    func respond(to interactionID: String, with decision: AgentDecision) async throws

    func listThreads() async throws -> [AgentThread]
    func readThread(_ sessionID: String) async throws -> AgentThread?
    func forkThread(_ thread: AgentThread) async throws -> AgentThread
    func createThread(directory: String) async throws -> AgentThread
    func prepareLaunch(for thread: AgentThread, intent: AgentLaunchIntent) async throws -> AgentLaunch
    func stopThread(_ thread: AgentThread) async throws
    func renameThread(_ thread: AgentThread, to title: String) async throws
    func markRead(_ thread: AgentThread) async throws -> AgentReadState
    func markUnread(_ thread: AgentThread) async throws -> AgentReadState
    func deleteThread(_ thread: AgentThread) async throws
    /// The most recent part of the conversation, oldest first.
    func transcript(for thread: AgentThread) async throws -> [TranscriptMessage]
    /// Requires `.prompt`. Images are local files attached to the prompt.
    func sendPrompt(_ text: String, images: [URL], to thread: AgentThread) async throws
    /// Rewinds conversation only and returns original attachments for the replacement prompt.
    func rewind(_ thread: AgentThread, before messageID: String) async throws -> (messages: [TranscriptMessage], images: [Data])
    /// Requires `.prompt`.
    func interrupt(_ thread: AgentThread) async throws
    /// Requires `.selectModel`. The models threads can switch to, as the provider's own picker lists them.
    func models() async throws -> [AgentModel]
    /// Requires `.selectModel` and `.prompt`. Applies the change from the thread's next turn.
    func changeSettings(_ change: AgentSettingsChange, of thread: AgentThread) async throws
    /// Requires `.selectModel` and `.terminalPrompt`. The commands that make the change when typed
    /// into the thread's terminal. The adapter reports the change from then on, until the provider does.
    func terminalCommands(for change: AgentSettingsChange, of thread: AgentThread) throws -> [String]
    func didExit(_ thread: AgentThread)
    /// Suspend background work when hidden, preserving resources needed by retained terminals.
    func setEnabled(_ isEnabled: Bool)
}

extension AgentProviderAdapter {
    var capabilities: AgentCapabilities { [] }

    func openConversation(_ thread: AgentThread) async throws {}

    func respond(to interactionID: String, with decision: AgentDecision) async throws {
        throw IntegrationError(message: "This request must be answered in the terminal.")
    }

    func forkThread(_ thread: AgentThread) async throws -> AgentThread {
        throw IntegrationError(message: "\(provider.name) does not support forking a thread.")
    }

    func markRead(_ thread: AgentThread) async throws -> AgentReadState {
        throw IntegrationError(message: "\(provider.name) does not support marking a thread read.")
    }

    func markUnread(_ thread: AgentThread) async throws -> AgentReadState {
        throw IntegrationError(message: "\(provider.name) does not support marking a thread unread.")
    }

    func deleteThread(_ thread: AgentThread) async throws {
        throw IntegrationError(message: "\(provider.name) does not support deleting a thread.")
    }

    func renameThread(_ thread: AgentThread, to title: String) async throws {
        throw IntegrationError(message: "\(provider.name) does not support renaming a thread.")
    }

    func transcript(for thread: AgentThread) async throws -> [TranscriptMessage] {
        throw IntegrationError(message: "\(provider.name) does not provide conversation history.")
    }

    func sendPrompt(_ text: String, images: [URL], to thread: AgentThread) async throws {
        throw IntegrationError(message: "\(provider.name) does not accept prompts from Atrium.")
    }

    func rewind(_ thread: AgentThread, before messageID: String) async throws -> (messages: [TranscriptMessage], images: [Data]) {
        throw IntegrationError(message: "\(provider.name) doesn’t support conversation editing.")
    }

    func interrupt(_ thread: AgentThread) async throws {
        throw IntegrationError(message: "\(provider.name) cannot be stopped from Atrium.")
    }

    func models() async throws -> [AgentModel] { [] }

    func changeSettings(_ change: AgentSettingsChange, of thread: AgentThread) async throws {
        throw IntegrationError(message: "\(provider.name) can’t change models from Atrium.")
    }

    func terminalCommands(for change: AgentSettingsChange, of thread: AgentThread) throws -> [String] {
        throw IntegrationError(message: "\(provider.name) can’t change models from Atrium.")
    }

    func didExit(_ thread: AgentThread) {}
    func setEnabled(_ isEnabled: Bool) {}
}
