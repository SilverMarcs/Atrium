import Foundation

nonisolated enum ServerFrame: Codable, Sendable {
    case reply(id: UInt32, reply: CompanionReply)
    case event(CompanionEvent)
}
