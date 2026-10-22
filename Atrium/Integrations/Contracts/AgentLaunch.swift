/// A terminal launch description. Callers never assemble provider flags or connection settings.
struct AgentLaunch: Sendable {
    let executable: String
    let arguments: [String]
}
