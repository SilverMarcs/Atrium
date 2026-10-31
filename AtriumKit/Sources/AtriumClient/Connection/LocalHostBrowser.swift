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
    private var isStarted = false
    private var restartTask: Task<Void, Never>?

    func start() {
        isStarted = true
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: HostProtocol.localServiceType, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self, weak browser] results, _ in
            MainActor.assumeIsolated {
                guard let self, self.browser === browser else { return }
                self.update(results)
            }
        }
        browser.stateUpdateHandler = { [weak self, weak browser] state in
            guard case .failed = state else { return }
            MainActor.assumeIsolated {
                guard let self, self.browser === browser else { return }
                // A failed browser finds nothing more, as after mDNSResponder
                // drops a suspended app, so it's replaced shortly.
                self.restartTask?.cancel()
                self.restartTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(2))
                    guard !Task.isCancelled else { return }
                    self?.restart()
                }
            }
        }
        self.browser = browser
        browser.start(queue: .main)
    }

    /// Browses afresh, reporting every host found even if it was found before,
    /// as after the app returns to the foreground or the network changes.
    /// Does nothing until started.
    func restart() {
        guard isStarted else { return }
        restartTask?.cancel()
        restartTask = nil
        browser?.cancel()
        browser = nil
        endpoints = [:]
        start()
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
