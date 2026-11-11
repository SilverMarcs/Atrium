/// The agent's own interface, attached to a running thread, to open in a terminal.
/// Callers never assemble provider flags or connection settings.
struct AgentLaunch: Sendable {
    let executable: String
    let arguments: [String]
}
