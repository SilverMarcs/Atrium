import Foundation

@MainActor
protocol AgentBackend: AnyObject {
    var onEvent: ((AgentEvent) -> Void)? { get set }
    var onFailure: ((Error) -> Void)? { get set }
    var canSteer: Bool { get }
    func steer(_ input: AgentInput) async throws
    func catalog() async throws -> AgentCatalog
    func connect(_ settings: AgentSettings) async throws -> AgentConnection
    func send(_ input: AgentInput, settings: AgentSettings) async throws
    func stop() async throws
    func close()
}
