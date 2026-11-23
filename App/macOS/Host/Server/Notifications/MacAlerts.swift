import Foundation

/// Alerts on this Mac. The host decides when to alert, as it does for
/// phones; the app it runs in shows the alerts and opens what they're about.
@MainActor
public protocol MacAlerts: AnyObject {
    /// A task finished, or needs an answer when `needsInput`.
    func alert(taskID: String, title: String, projectName: String, needsInput: Bool, projectIcon: Data?)
    /// A saved command rang the terminal bell, as a program waiting on a
    /// reply does. Its project is named while it's still there.
    func alert(commandID: UUID, commandName: String, workspaceID: UUID?, workspaceName: String?)
    /// Everything counts as seen: drop this Mac's alerts and badge.
    func clearAlerts()
}
