import SwiftUI

/// The pull requests linked to a task, in the Mac toolbar, with a tooltip for
/// the most pressing one.
struct PullRequestMenu: View {
    let item: HostTask
    private var pullRequests: [PullRequest] { item.task.pullRequests }

    var body: some View {
        if let lead = pullRequests.mostPressing {
            Menu("Pull Requests", image: lead.icon) {
                PullRequestButtons(item: item)
            }
            .foregroundStyle(lead.tint)
            #if os(macOS)
            .menuIndicator(.hidden)
            .help("\(lead.numberText): \(lead.detail)")
            #endif
        }
    }
}

/// One button for each pull request, opening it on GitHub, with its state,
/// checks and review beneath its title, and its repository when they're in
/// several; on the Mac, then one reviewing their changes and one opening
/// them all.
struct PullRequestButtons: View {
    let item: HostTask
    private var pullRequests: [PullRequest] { item.task.pullRequests }
    @Environment(\.openURL) private var openURL
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif

    var body: some View {
        // Numbers repeat across repositories, so a task with pull requests in several names each one's.
        let namesRepository = Set(pullRequests.map(\.repository)).count > 1
        ForEach(pullRequests) { pullRequest in
            Button {
                reportPullRequestOpened()
                openURL(pullRequest.url)
            } label: {
                Label(pullRequest.menuTitle, image: pullRequest.icon)
                Text(namesRepository ? "\(pullRequest.repositoryName) · \(pullRequest.detail)" : pullRequest.detail)
            }
        }
        // Mac menus leave out item icons unless asked for.
        .labelStyle(.titleAndIcon)

        #if os(macOS)
        let reviews = reviewWindows
        if !reviews.isEmpty || pullRequests.count > 1 {
            Divider()
        }
        if !reviews.isEmpty {
            Button("Review Changes", systemImage: "text.magnifyingglass") {
                // Last first, as each joins the tabs in front of the others.
                for review in reviews.reversed() { openWindow(value: review) }
            }
            .labelStyle(.titleAndIcon)
        }
        // iOS opens just the first: the app goes to the background as Safari
        // comes up, and the rest are dropped.
        if pullRequests.count > 1 {
            Button("Open All", systemImage: "arrow.up.right") {
                reportPullRequestOpened()
                for pullRequest in pullRequests { openURL(pullRequest.url) }
            }
            .labelStyle(.titleAndIcon)
        }
        #endif
    }

    #if os(macOS)
    /// A diff window for each pull request whose repository is checked out
    /// in the task's project, as tabs of one window.
    private var reviewWindows: [GitDiffWindowItem] {
        guard let workspaceID = item.task.workspaceID else { return [] }
        return pullRequests.compactMap { pullRequest in
            pullRequest.local.map {
                GitDiffWindowItem(
                    project: WorkspaceRef(hostID: item.host.id, workspaceID: workspaceID),
                    repositoryRootURL: $0.repository,
                    subject: .pullRequest(task: item.id, url: pullRequest.url)
                )
            }
        }
    }
    #endif

    private func reportPullRequestOpened() {
        // Best effort, since opening GitHub can put Atrium in the background.
        Task { _ = try? await item.host.request(.openedPullRequest(taskID: item.task.id)) }
    }
}
