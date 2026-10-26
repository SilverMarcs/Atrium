import Foundation

/// A task alert the Mac asks the relay to send to one phone through APNs.
/// It's the only thing on the relay that isn't end-to-end encrypted.
struct RelayPushAlert: Encodable {
    let type = "push"
    var token: String
    var environment: CompanionPushRegistration.Environment
    var title: String
    var body: String
    var taskID: String
}
