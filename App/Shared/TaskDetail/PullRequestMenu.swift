import AtriumClient
import AtriumProtocol
import SwiftUI

/// The pull requests linked to a task, in the Mac toolbar. Its icon shows
/// the most pressing one's state.
struct PullRequestMenu: View {
    let item: HostTask
    private var pullRequests: [PullRequest] { item.task.pullRequests }

    var body: some View {
        if let lead = pullRequests.mostPressing {
            Menu("Pull Requests", systemImage: lead.systemImage) {
                PullRequestButtons(item: item)
            }
            #if os(macOS)
            .menuIndicator(.hidden)
            .help("\(lead.numberText): \(lead.summary)")
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
                Label(pullRequest.menuTitle, systemImage: pullRequest.systemImage)
                Text(namesRepository ? "\(pullRequest.repositoryName) · \(pullRequest.detail)" : pullRequest.detail)
            }
        }
        #if os(macOS)
        // iOS opens just the first: the app goes to the background as Safari
        // comes up, and the rest are dropped.
        if pullRequests.count > 1 {
            Divider()
            Button("Open All", systemImage: "arrow.up.right") {
                reportPullRequestOpened()
                for pullRequest in pullRequests { openURL(pullRequest.url) }
            }
            // Mac menus leave out item icons unless asked for.
            .labelStyle(.titleAndIcon)
        }
        #endif
    }

    private func reportPullRequestOpened() {
        // Best effort, since opening GitHub can put Atrium in the background.
        Task { _ = try? await item.host.request(.openedPullRequest(taskID: item.task.id)) }
    }
}
