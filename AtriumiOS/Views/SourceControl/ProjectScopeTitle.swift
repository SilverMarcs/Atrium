import AtriumClient
import AtriumProtocol
import SwiftUI

/// The title Source Control, Files and Search share: the branch the project's
/// scope shows, its repository under it, and a title menu picking the branch
/// or worktree and the repository, the same on every page. The menu is left
/// out when there's nothing to pick, since an empty one still shows as a menu.
/// It presents what picking a branch asks to confirm, and its errors.
private struct ProjectScopeTitle: ViewModifier {
    @State private var source: SourceControl
    let placeholder: String
    let title: String?
    let onNewBranch: (() -> Void)?

    init(source: SourceControl, placeholder: String, title: String?, onNewBranch: (() -> Void)?) {
        _source = State(initialValue: source)
        self.placeholder = placeholder
        self.title = title
        self.onNewBranch = onNewBranch
    }

    func body(content: Content) -> some View {
        let status = source.status
        let titled = content
            .navigationTitle(title ?? status.map { $0.branchName ?? "Detached HEAD" } ?? placeholder)
            .navigationSubtitle(title == nil ? status?.name ?? "" : "")
            .toolbarTitleDisplayMode(.inline)
            .task(id: source.scope.gitScope) {
                await source.host.follow(.git(source.scope.gitScope))
            }
            .sourceControlAlerts(source)
        if title == nil, let status, BranchMenuItems.hasChoices(in: status, repositories: source.repositories) {
            titled.toolbarTitleMenu {
                BranchMenuItems(source: source, status: status, onNewBranch: onNewBranch)
            }
        } else {
            titled
        }
    }
}

extension View {
    /// Titles a page of a project by the branch and repository its scope shows.
    /// - Parameters:
    ///   - placeholder: The title until the project's status arrives.
    ///   - title: A title of its own in place of the branch and its menu, as a
    ///     subfolder in Files has.
    func projectScopeTitle(host: HostClient, workspaceID: UUID, placeholder: String, title: String? = nil) -> some View {
        modifier(ProjectScopeTitle(
            source: SourceControl(host: host, workspaceID: workspaceID), placeholder: placeholder, title: title, onNewBranch: nil
        ))
    }

    /// Titles the page showing `source`, which also presents what it asks to
    /// confirm and its errors.
    /// - Parameter onNewBranch: Asks for a new branch's name.
    func projectScopeTitle(_ source: SourceControl, placeholder: String, onNewBranch: @escaping () -> Void) -> some View {
        modifier(ProjectScopeTitle(source: source, placeholder: placeholder, title: nil, onNewBranch: onNewBranch))
    }
}
