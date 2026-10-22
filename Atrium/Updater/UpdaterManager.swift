import Foundation
import Observation
import Sparkle

/// Observable wrapper around Sparkle's `SPUStandardUpdaterController` so that SwiftUI views
/// can drive Sparkle's updater and react to its state.
///
/// Starts update checks only when this build has an Atrium feed and signing key configured.
@MainActor
@Observable
final class UpdaterManager {
    let isConfigured: Bool

    /// Mirrors `SPUUpdater.canCheckForUpdates`. Used to disable the menu/button while a
    /// check is already in flight.
    private(set) var canCheckForUpdates: Bool = false

    /// Two-way bound from the Settings UI. Writes through to the underlying updater.
    var automaticallyChecksForUpdates: Bool = true {
        didSet {
            guard isConfigured,
                  controller.updater.automaticallyChecksForUpdates != automaticallyChecksForUpdates else { return }
            controller.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        }
    }

    /// Update check interval in seconds. Sparkle enforces a 1-hour minimum.
    var updateCheckInterval: TimeInterval = 86_400 {
        didSet {
            guard isConfigured,
                  controller.updater.updateCheckInterval != updateCheckInterval else { return }
            controller.updater.updateCheckInterval = updateCheckInterval
        }
    }

    @ObservationIgnored let controller: SPUStandardUpdaterController
    @ObservationIgnored private var canCheckObservation: NSKeyValueObservation?

    init() {
        let feedURL = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String
        let signingKey = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        isConfigured = feedURL?.isEmpty == false && signingKey?.isEmpty == false

        controller = SPUStandardUpdaterController(
            startingUpdater: isConfigured,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )

        guard isConfigured else { return }

        // Seed local state from the updater. didSet won't fire from init, so this won't
        // create a feedback loop.
        automaticallyChecksForUpdates = controller.updater.automaticallyChecksForUpdates
        updateCheckInterval = controller.updater.updateCheckInterval

        canCheckObservation = controller.updater.observe(
            \.canCheckForUpdates,
            options: [.initial, .new]
        ) { [weak self] updater, _ in
            let value = updater.canCheckForUpdates
            Task { @MainActor in
                self?.canCheckForUpdates = value
            }
        }
    }

    /// Triggered by the menu bar and Settings "Check Now" button. Shows Sparkle's standard UI.
    func checkForUpdates() {
        guard isConfigured else { return }
        controller.checkForUpdates(nil)
    }
}
