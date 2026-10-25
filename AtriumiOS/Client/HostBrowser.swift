import Foundation
import Network

/// Finds Macs advertising the companion service with Bonjour.
@MainActor
final class HostBrowser {
    var onChange: (([DiscoveredHost]) -> Void)?
    private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: CompanionProtocol.bonjourServiceType, domain: nil), using: parameters)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            MainActor.assumeIsolated {
                let hosts = results.compactMap { result -> DiscoveredHost? in
                    guard case .service(let name, _, _, _) = result.endpoint else { return nil }
                    return DiscoveredHost(name: name, endpoint: result.endpoint)
                }
                self?.onChange?(hosts.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }
}
