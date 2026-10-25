import Foundation
import Network

/// A Mac advertising Atrium on the local network, named after the computer.
struct DiscoveredHost: Identifiable, Hashable {
    let name: String
    let endpoint: NWEndpoint

    var id: String { name }
}
