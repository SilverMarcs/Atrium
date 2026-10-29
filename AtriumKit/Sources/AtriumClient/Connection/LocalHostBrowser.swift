#if canImport(Network)
import AtriumProtocol
import Foundation
import Network

/// Finds hosts advertising themselves on the local network, by host ID, so a
/// client can reach a paired host directly instead of through the relay.
@MainActor
final class LocalHostBrowser {
    /// Called whenever the hosts found change.
    var onChange: (() -> Void)?
    private(set) var endpoints: [String: NWEndpoint] = [:]
    private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: HostProtocol.localServiceType, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            MainActor.assumeIsolated { self?.update(results) }
        }
        self.browser = browser
        browser.start(queue: .main)
    }

    private func update(_ results: Set<NWBrowser.Result>) {
        var endpoints: [String: NWEndpoint] = [:]
        for result in results {
            guard case .bonjour(let record) = result.metadata, let hostID = record[HostProtocol.localHostIDKey] else { continue }
            endpoints[hostID] = result.endpoint
        }
        guard endpoints != self.endpoints else { return }
        self.endpoints = endpoints
        onChange?()
    }
}
#endif
