import SwiftUI

/// Shows the checkouts a task works in, in its project's scope, when the task
/// opens and as it works. Also follows the project's Git status, which the
/// scope's pages, pickers and titles read.
private struct ProjectScopeFollower: ViewModifier {
    let item: HostTask?
    /// The scope following the task shown, released when another project's task or none is.
    @State private var followedScope: ProjectScope?

    private var scope: ProjectScope? {
        guard let item, let workspaceID = item.task.workspaceID else { return nil }
        return item.host.scope(for: workspaceID)
    }

    func body(content: Content) -> some View {
        content
            .onChange(of: item?.id, initial: true) {
                let scope = scope
                if followedScope !== scope { followedScope?.release() }
                followedScope = scope
                if let task = item?.task { scope?.show(task) }
            }
            // A subagent or side chat opened over the task followed in its place.
            .onAppear {
                if let task = item?.task { scope?.follow(task) }
            }
            .onChange(of: item?.task.changedCheckouts) { update() }
            .onChange(of: item?.task.checkout) { update() }
            .task(id: scope?.gitScope) {
                guard let item, let scope else { return }
                await item.host.follow(.git(scope.gitScope))
            }
    }

    private func update() {
        if let task = item?.task { scope?.update(task) }
    }
}

extension View {
    func followsProjectScope(of item: HostTask?) -> some View {
        modifier(ProjectScopeFollower(item: item))
    }
}
