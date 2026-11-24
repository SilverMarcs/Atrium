import SwiftUI

/// The pull requests linked to a task, in the Mac toolbar, with a count when
/// there are several and a tooltip for the most pressing one.
struct PullRequestMenu: View {
    let item: HostTask
    private var pullRequests: [PullRequest] { item.task.pullRequests }

    var body: some View {
        if let lead = pullRequests.mostPressing {
            Menu("Pull Requests", image: lead.icon) {
                PullRequestButtons(item: item)
            }
            // A zero badge is hidden.
            .badge(pullRequests.count > 1 ? pullRequests.count : 0)
            #if os(macOS)
            .menuIndicator(.hidden)
            .help("\(lead.numberText): \(lead.detail)")
            #endif
        }
    }
}

/// One button for each pull request, opening it on GitHub, with its state,
/// checks and review beneath its title, and its repository when they're in
/// several; on the Mac, then one opening them all.
struct PullRequestButtons: View {
    let item: HostTask
    private var pullRequests: [PullRequest] { item.task.pullRequests }
    @Environment(\.openURL) private var openURL

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
        // iOS opens just the first: the app goes to the background as Safari
        // comes up, and the rest are dropped.
        if pullRequests.count > 1 {
            Divider()
            Button("Open All", systemImage: "arrow.up.right") {
                reportPullRequestOpened()
                for pullRequest in pullRequests { openURL(pullRequest.url) }
            }
            .labelStyle(.titleAndIcon)
        }
        #endif
    }

    private func reportPullRequestOpened() {
        // Best effort, since opening GitHub can put Atrium in the background.
        Task { _ = try? await item.host.request(.openedPullRequest(taskID: item.task.id)) }
    }
}
