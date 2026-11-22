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
    /// Forks a thread with its conversation, or only the part before a prompt, as the
    /// prompt's `editTarget` names it.
    func forkThread(_ thread: AgentThread, before messageID: String?) async throws -> AgentThread
    /// Starts a side chat about a thread's conversation so far, which the
    /// adapter lists, prompts and interrupts like a thread until `endSideChat` or the provider ends it.
    func startSideChat(of thread: AgentThread) async throws -> AgentThread
    func endSideChat(_ thread: AgentThread) async
    /// A new thread, named `title` when one is given.
    func createThread(directory: String, settings: TaskStartSettings?, title: String?) async throws -> AgentThread
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
    /// The whole conversation, oldest first.
    func transcript(for thread: AgentThread) async throws -> [TranscriptMessage]
    /// Images are local files attached to the prompt.
    func sendPrompt(_ text: String, images: [URL], to thread: AgentThread) async throws
    func skills(in directory: String) async throws -> [AgentSkill]
    /// The original images of a prompt, to show or send again, as its message
    /// ID or `editTarget` names it.
    func promptImages(of thread: AgentThread, messageID: String) async throws -> [Data]
    /// Rewinds conversation only, to before a prompt, and returns what's left.
    func rewind(_ thread: AgentThread, before messageID: String) async throws -> [TranscriptMessage]
    func interrupt(_ thread: AgentThread) async throws
    /// Ends what a thread keeps running after its turn is interrupted, such as
    /// background commands and agents.
    func endBackgroundWork(_ thread: AgentThread) async throws
    /// The models threads can switch to, as the provider's own picker lists them.
    func models() async throws -> [AgentModel]
    /// Applies the change from the thread's next turn.
    func changeSettings(_ change: AgentSettingsChange, of thread: AgentThread) async throws
    /// Suspends background work while the provider is turned off.
    func setEnabled(_ isEnabled: Bool)
    /// Live output for a provider-buffered background session, or nil when unavailable.
    func backgroundSessionOutput(for session: AgentBackgroundSession) async -> WireCommandOutput?
}

extension AgentProviderAdapter {
    func markRead(_ thread: AgentThread) async throws -> AgentReadState {
        throw IntegrationError(message: "\(provider.name) does not support marking a thread read.")
    }

    func markUnread(_ thread: AgentThread) async throws -> AgentReadState {
        throw IntegrationError(message: "\(provider.name) does not support marking a thread unread.")
    }

    func backgroundSessionOutput(for session: AgentBackgroundSession) async -> WireCommandOutput? { nil }
}
