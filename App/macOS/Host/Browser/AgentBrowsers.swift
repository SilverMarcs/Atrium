import Foundation
import Observation

/// The browser each chat on this Mac has opened, by task ID, until the chat
/// is settled or deleted, or the browser sits unused. Each holds a web page
/// process, so none starts before its agent or the user opens a page, and
/// one nobody has used or looked at for a while closes.
@MainActor
@Observable
final class AgentBrowsers {
    /// How long a browser the agent isn't using and no view shows stays open.
    static let idleLimit: Duration = .seconds(10 * 60)
    /// How long the agent's mark stays once its turn ends, in case it goes on.
    static let turnEndGrace: Duration = .seconds(4)

    private(set) var browsers: [String: AgentBrowser] = [:]
    /// A chat's browser opened, by task ID, for the window to show it.
    @ObservationIgnored var onOpen: ((String) -> Void)?
    /// Closes browsers left idle, while any are open.
    @ObservationIgnored private var idleSweep: Task<Void, Never>?

    func browser(for taskID: String) -> AgentBrowser? {
        browsers[taskID]
    }

    /// The chat's agent used its browser: it's marked as in use for the rest
    /// of the agent's turn, however many pages the turn goes through.
    func noteAgentUse(by taskID: String) {
        browsers[taskID]?.noteAgentUse()
    }

    /// A chat's agent started or stopped working, which ends its browser's mark.
    func observe(_ thread: AgentThread) {
        browsers[thread.id]?.agentWorkingChanged(thread.status.isWorking, grace: Self.turnEndGrace)
    }

    /// The chat's browser, opening one when it has none.
    func browserOpening(for taskID: String) -> AgentBrowser {
        if let browser = browsers[taskID] {
            browser.lastUsed = .now
            return browser
        }
        let browser = AgentBrowser()
        browsers[taskID] = browser
        startIdleSweep()
        onOpen?(taskID)
        return browser
    }

    func close(_ taskID: String) {
        guard let browser = browsers.removeValue(forKey: taskID) else { return }
        browser.close()
        if browsers.isEmpty {
            idleSweep?.cancel()
            idleSweep = nil
        }
    }

    /// Once a minute, closes each browser that's been neither used by its
    /// agent nor shown anywhere for `idleLimit`. A browser on screen counts
    /// as in use, since the user may be using it.
    private func startIdleSweep() {
        guard idleSweep == nil else { return }
        idleSweep = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                self?.closeIdle()
            }
        }
    }

    private func closeIdle() {
        let now = ContinuousClock.now
        for (taskID, browser) in browsers {
            if browser.isAgentUsing || browser.isOnScreen {
                browser.lastUsed = now
            } else if now - browser.lastUsed >= Self.idleLimit {
                close(taskID)
            }
        }
    }
}
