import Foundation

/// A phone's APNs device token, which the Mac hands to the relay with each
/// task alert for that phone.
public nonisolated struct PushRegistration: Codable, Sendable, Hashable {
    /// Which APNs servers issued the token: development-signed builds get
    /// sandbox tokens.
    public enum Environment: String, Codable, Sendable {
        case sandbox
        case production
    }

    /// The device token, as lowercase hex.
    public var token: String
    public var environment: Environment

    public init(token: String, environment: Environment) {
        self.token = token
        self.environment = environment
    }
}
