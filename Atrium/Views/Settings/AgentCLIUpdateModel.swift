import Foundation
import Observation

@MainActor
@Observable
final class AgentCLIUpdateModel {
    private(set) var installation: AgentCLIInstallation?
    private(set) var latestVersion: String?
    private(set) var isChecking = false
    private(set) var isUpdating = false
    private(set) var checkFailed = false
    private(set) var errorMessage = ""
    var showingError = false

    var updateAvailable: Bool {
        guard let installation, let latestVersion else { return false }
        return latestVersion.compare(installation.version, options: .numeric) == .orderedDescending
    }

    var status: String {
        if isUpdating { return "Updating…" }
        if isChecking { return "Checking for updates…" }
        let version = installation.map { "Version \($0.version) · " } ?? ""
        if checkFailed { return version + "Update check unavailable" }
        if let latestVersion, updateAvailable { return version + "\(latestVersion) available" }
        return version + "Up to date"
    }

    var buttonTitle: String { latestVersion == nil && checkFailed ? "Check Again" : "Update" }
    var isDisabled: Bool { isChecking || isUpdating || (!checkFailed && !updateAvailable) }

    func refresh(_ provider: AgentProvider) async {
        guard !isUpdating, !isChecking else { return }
        isChecking = true
        checkFailed = false
        latestVersion = nil
        defer { isChecking = false }
        do {
            let installed = try await AgentCLIInstallation.read(provider)
            installation = installed
            let version = try await installed.latestVersion()
            try Task.checkCancellation()
            latestVersion = version
        } catch {
            guard !Task.isCancelled else { return }
            checkFailed = true
        }
    }

    func performAction(_ provider: AgentProvider) async {
        if checkFailed { return await refresh(provider) }
        guard updateAvailable, !isUpdating, let installation, let latestVersion else { return }
        isUpdating = true
        defer { isUpdating = false }
        do {
            _ = try await IntegrationProcess.run(installation.updateCommand, arguments: installation.updateArguments, timeout: .seconds(300))
            let updated = try await AgentCLIInstallation.read(provider)
            self.installation = updated
            guard updated.version.compare(latestVersion, options: .numeric) != .orderedAscending else {
                throw IntegrationError(message: "The updater finished, but \(provider.name) is still reporting version \(updated.version).")
            }
        } catch {
            errorMessage = error.localizedDescription
            showingError = true
        }
    }
}
