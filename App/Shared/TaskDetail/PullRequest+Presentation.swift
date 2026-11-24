import DeveloperToolsSupport
import SwiftUI

extension PullRequest {
    var icon: ImageResource {
        switch state {
        case .open: .gitPullRequest
        case .draft: .gitPullRequestDraft
        case .merged: .gitMerge
        case .closed: .gitPullRequestClosed
        }
    }

    /// GitHub's color for its state, on its icon in the sidebar and toolbar.
    var tint: Color {
        switch state {
        case .open: .green
        case .draft: .secondary
        case .merged: .purple
        case .closed: .red
        }
    }

    /// Whether it's still in progress, as a draft or open for review.
    var isOpen: Bool { state == .open || state == .draft }

    var stateName: String {
        switch state {
        case .open: "Open"
        case .draft: "Draft"
        case .merged: "Merged"
        case .closed: "Closed"
        }
    }

    /// The state, checks and review, for menu subtitles and tooltips.
    var detail: String {
        var parts = [stateName]
        if isOpen {
            switch checks {
            case .passing: parts.append("Checks passed")
            case .failing: parts.append("Checks failing")
            case .pending: parts.append("Checks pending")
            case nil: parts.append("No checks reported")
            }
            switch review {
            case .approved: parts.append("Approved")
            case .changesRequested: parts.append("Changes requested")
            case .required: parts.append("Review required")
            case nil: break
            }
        }
        return parts.joined(separator: " · ")
    }

    /// The number as "#1657". Interpolating the number into a localized
    /// string key would group it as "#1,657".
    var numberText: String { "#\(number)" }

    /// Menu titles wrap at this many characters a line.
    static let menuTitleLineLength = 35

    /// The number and title for a menu item, wrapped onto two lines at most,
    /// ending in "…" when the title runs longer. Menus don't wrap on their own.
    var menuTitle: String {
        let words = [numberText] + title.split(whereSeparator: \.isWhitespace).map(String.init)
        var lines: [String] = []
        var line = ""
        var shown = 0
        for word in words {
            if line.isEmpty {
                line = word
            } else if line.count + 1 + word.count <= Self.menuTitleLineLength {
                line += " " + word
            } else {
                lines.append(line)
                if lines.count == 2 { break }
                line = word
            }
            shown += 1
        }
        if lines.count < 2 { lines.append(line) }
        if shown < words.count { lines[lines.count - 1] += "…" }
        return lines.joined(separator: "\n")
    }

    /// The repository's name without its owner.
    var repositoryName: String { repository.split(separator: "/").last.map(String.init) ?? repository }

    /// How much it needs the user, so a task shows its most pressing one.
    fileprivate var urgency: Int {
        switch (state, checks) {
        case (.open, .failing), (.draft, .failing): 4
        case (.open, _): 3
        case (.draft, _): 2
        case (.merged, _): 1
        case (.closed, _): 0
        }
    }
}

extension [PullRequest] {
    /// The one a task's toolbar and row stand for: failing checks first, then open work.
    var mostPressing: PullRequest? { self.max { $0.urgency < $1.urgency } }
}

/// The state of a task's most pressing pull request, for its sidebar row,
/// followed by how many it has when more than one.
struct PullRequestIndicator: View {
    let pullRequests: [PullRequest]
    @ScaledMetric(relativeTo: .subheadline) private var iconSize: CGFloat = 11

    var body: some View {
        if let pullRequest = pullRequests.mostPressing {
            HStack(spacing: 2) {
                Image(pullRequest.icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: iconSize, height: iconSize)
                    .foregroundStyle(pullRequest.tint)
                    .accessibilityLabel("\(pullRequest.numberText) \(pullRequest.detail)")
                if pullRequests.count > 1 {
                    Text(pullRequests.count, format: .number)
                        .monospacedDigit()
                }
            }
            .help("\(pullRequest.numberText) \(pullRequest.detail)")
        }
    }
}
