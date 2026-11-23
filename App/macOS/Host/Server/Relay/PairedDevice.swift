import AtriumProtocol
import Foundation

/// A client allowed to connect. Only a hash of its token is kept, so the
/// stored list can't be replayed to impersonate the device.
struct PairedDevice: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    /// An agent such as ChatGPT, whose sessions are listed under its name, or an app.
    var kind: ClientDevice.Kind?
    /// What an agent may do with the host's tools, as the user approved it.
    var access: AgentAccess?
    let tokenHash: String
    let pairedAt: Date
    var lastConnectedAt: Date?
    /// Where to send this device's task alerts, once it has registered for them.
    var push: PushRegistration?
}
