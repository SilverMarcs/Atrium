import AtriumProtocol
import Foundation

/// Provider boundary. Implementations own connections, SDKs, wire formats, and CLI options.
/// Events and snapshots use only the shared models consumed by AgentIntegrationStore.
@MainActor
protocol AgentProviderAdapter: AnyObject {
    var provider: AgentProvider { get }
    var capabilities: AgentCapabilities { get }
    var defaultSettings: TaskStartSettings? { get }
    var onEvent: ((AgentEvent) -> Void)? { get set }

    /// Opens the provider connection, so the thread's live events flow.
    func openConversation(_ thread: AgentThread) async throws
    func respond(to interactionID: String, with decision: AgentDecision) async throws

    func listThreads() async throws -> [AgentThread]
    func readThread(_ sessionID: String) async throws -> AgentThread?
    func forkThread(_ thread: AgentThread) async throws -> AgentThread
    /// Requires `.sideChat`. Starts a side chat about a thread's conversation so far, which the
    /// adapter lists, prompts and interrupts like a thread until `endSideChat` or the provider ends it.
    func startSideChat(of thread: AgentThread) async throws -> AgentThread
    func endSideChat(_ thread: AgentThread) async
    /// A new thread, named `title` when one is given. In a new worktree, it
    /// works in a linked worktree of the repository whose main checkout
    /// `directory` is, from its checked-out commit, created and named the way
    /// the provider's own agent does.
    func createThread(directory: String, settings: TaskStartSettings?, title: String?, inNewWorktree: Bool) async throws -> AgentThread
    /// The tokens the model a thread runs can take in at once, as its provider
    /// works it out, or nil when the provider doesn't say.
    func contextWindow(for thread: AgentThread) async -> Int?
    /// Opens the thread's conversation and describes the agent's interface attached
    /// to it, without starting another conversation.
    func prepareLaunch(for thread: AgentThread) async throws -> AgentLaunch
    func stopThread(_ thread: AgentThread) async throws
    func renameThread(_ thread: AgentThread, to title: String) async throws
    func markRead(_ thread: AgentThread) async throws -> AgentReadState
    func markUnread(_ thread: AgentThread) async throws -> AgentReadState
    func deleteThread(_ thread: AgentThread) async throws
    /// The most recent part of the conversation, oldest first.
    func transcript(for thread: AgentThread) async throws -> [TranscriptMessage]
    /// Images are local files attached to the prompt.
    func sendPrompt(_ text: String, images: [URL], to thread: AgentThread) async throws
    /// Rewinds conversation only and returns original attachments for the replacement prompt.
    func rewind(_ thread: AgentThread, before messageID: String) async throws -> (messages: [TranscriptMessage], images: [Data])
    func interrupt(_ thread: AgentThread) async throws
    /// Ends what a thread keeps running after its turn is interrupted, such as
    /// background commands and agents.
    func endBackgroundWork(_ thread: AgentThread) async throws
    /// Requires `.selectModel`. The models threads can switch to, as the provider's own picker lists them.
    func models() async throws -> [AgentModel]
    /// Requires `.selectModel`. Applies the change from the thread's next turn.
    func changeSettings(_ change: AgentSettingsChange, of thread: AgentThread) async throws
    /// Suspends background work while the provider is turned off.
    func setEnabled(_ isEnabled: Bool)
}

extension AgentProviderAdapter {
    var capabilities: AgentCapabilities { [] }
    var defaultSettings: TaskStartSettings? { nil }

    func openConversation(_ thread: AgentThread) async throws {}

    func respond(to interactionID: String, with decision: AgentDecision) async throws {
        throw IntegrationError(message: "This request must be answered in the terminal.")
    }

    func forkThread(_ thread: AgentThread) async throws -> AgentThread {
        throw IntegrationError(message: "\(provider.name) does not support forking a thread.")
    }

    func startSideChat(of thread: AgentThread) async throws -> AgentThread {
        throw IntegrationError(message: "\(provider.name) does not support side chats.")
    }

    func endSideChat(_ thread: AgentThread) async {}

    func contextWindow(for thread: AgentThread) async -> Int? { nil }

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

    func rewind(_ thread: AgentThread, before messageID: String) async throws -> (messages: [TranscriptMessage], images: [Data]) {
        throw IntegrationError(message: "\(provider.name) doesn’t support conversation editing.")
    }

    func endBackgroundWork(_ thread: AgentThread) async throws {}

    func models() async throws -> [AgentModel] { [] }

    func changeSettings(_ change: AgentSettingsChange, of thread: AgentThread) async throws {
        throw IntegrationError(message: "\(provider.name) can’t change models from Atrium.")
    }

    func setEnabled(_ isEnabled: Bool) {}
}
