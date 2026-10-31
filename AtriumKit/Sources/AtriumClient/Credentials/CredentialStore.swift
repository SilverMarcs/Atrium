import AtriumProtocol
import Foundation

/// Where a client keeps its own identity, the hosts it's paired with and the
/// token each host issued it, in the Keychain.
@MainActor
public protocol CredentialStore: AnyObject {
    /// This install, as it introduces itself when pairing. Its id is stable.
    var device: ClientDevice { get }
    var pairedHosts: [PairedHost] { get }
    func token(for host: PairedHost) -> String?
    /// Adds or updates a host with its new token. Pairing the same host again
    /// keeps its place and the name chosen for it.
    func save(_ host: PairedHost, token: String) throws
    func rename(_ host: PairedHost, to name: String?)
    func forget(_ host: PairedHost)
}
