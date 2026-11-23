import Foundation

/// A task alert the host asks the relay to send to one phone through APNs.
/// It's the only thing on the relay that isn't end-to-end encrypted.
struct RelayPushAlert: Encodable {
    let type = "push"
    let hostID = HostIdentity.hostID
    var token: String
    var environment: PushRegistration.Environment
    /// The project name.
    var title: String
    /// The chat title.
    var subtitle: String
    var body: String
    var taskID: String
    /// Only a manually selected project icon, resized for native notifications.
    var projectIcon: Data? = nil
}
