import Foundation

/// A phone's APNs device token, which the Mac hands to the relay with each
/// task alert for that phone.
nonisolated struct CompanionPushRegistration: Codable, Sendable, Hashable {
    /// Which APNs servers issued the token: development-signed builds get
    /// sandbox tokens.
    enum Environment: String, Codable, Sendable {
        case sandbox
        case production
    }

    /// The device token, as lowercase hex.
    var token: String
    var environment: Environment
}
