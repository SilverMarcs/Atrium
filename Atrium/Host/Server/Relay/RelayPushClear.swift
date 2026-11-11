import AtriumProtocol
import Foundation

/// Asks the relay to clear a phone's badge and wake it to drop its alerts,
/// once Atrium has come to the front on another device.
struct RelayPushClear: Encodable {
    let type = "clear"
    var token: String
    var environment: PushRegistration.Environment
}
