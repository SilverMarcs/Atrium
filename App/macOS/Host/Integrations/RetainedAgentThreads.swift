import Foundation

/// Threads retained across launches, independently of providers still supported.
struct RetainedAgentThreads: Decodable {
    let threads: [AgentThread]

    init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var restored: [AgentThread] = []
        while !container.isAtEnd {
            // Advance before decoding so an unsupported provider skips only its own row.
            let entry = try container.superDecoder()
            if let thread = try? AgentThread(from: entry) { restored.append(thread) }
        }
        threads = restored
    }
}
