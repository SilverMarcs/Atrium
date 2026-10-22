import Foundation

/// Provider boundary. Implementations own connections, SDKs, wire formats, and CLI options.
/// Events and snapshots use only the shared models consumed by AgentIntegrationStore.
@MainActor
protocol AgentProviderAdapter: AnyObject {
    var provider: AgentProvider { get }
    var capabilities: AgentCapabilities { get }
    var onEvent: ((AgentEvent) -> Void)? { get set }

    func listThreads() async throws -> [AgentThread]
    func readThread(_ sessionID: String) async throws -> AgentThread?
    func createThread(directory: String) async throws -> AgentThread
    func prepareLaunch(for thread: AgentThread, intent: AgentLaunchIntent) async throws -> AgentLaunch
    func stopThread(_ thread: AgentThread) async throws
    func renameThread(_ thread: AgentThread, to title: String) async throws
    func markUnread(_ thread: AgentThread) async throws -> AgentReadState
    func deleteThread(_ thread: AgentThread) async throws
    func didExit(_ thread: AgentThread)
    /// Suspend background work when hidden, preserving resources needed by retained terminals.
    func setEnabled(_ isEnabled: Bool)
}

extension AgentProviderAdapter {
    var capabilities: AgentCapabilities { [] }

    func markUnread(_ thread: AgentThread) async throws -> AgentReadState {
        throw IntegrationError(message: "\(provider.name) does not support marking a thread unread.")
    }

    func deleteThread(_ thread: AgentThread) async throws {
        throw IntegrationError(message: "\(provider.name) does not support deleting a thread.")
    }

    func renameThread(_ thread: AgentThread, to title: String) async throws {
        throw IntegrationError(message: "\(provider.name) does not support renaming a thread.")
    }

    func didExit(_ thread: AgentThread) {}
    func setEnabled(_ isEnabled: Bool) {}
}
