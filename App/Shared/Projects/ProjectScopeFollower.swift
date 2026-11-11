import AtriumClient
import AtriumProtocol
import SwiftUI

/// Shows the checkout a task works in, in its project's scope: when the task
/// opens, and again whenever it moves into or out of a worktree. A checkout
/// picked in between stays until then. Also follows the project's Git status,
/// which the scope's pages, pickers and titles read.
private struct ProjectScopeFollower: ViewModifier {
    let item: HostTask?

    private var scope: ProjectScope? {
        guard let item, let workspaceID = item.task.workspaceID else { return nil }
        return item.host.scope(for: workspaceID)
    }

    func body(content: Content) -> some View {
        content
            .onChange(of: item?.id, initial: true) { showCheckout() }
            .onChange(of: item?.task.checkout) { showCheckout() }
            .task(id: scope?.gitScope) {
                guard let item, let scope else { return }
                await item.host.follow(.git(scope.gitScope))
            }
    }

    private func showCheckout() {
        scope?.show(item?.task.checkout)
    }
}

extension View {
    func followsProjectScope(of item: HostTask?) -> some View {
        modifier(ProjectScopeFollower(item: item))
    }
}
