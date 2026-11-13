import AtriumProtocol
import SwiftUI

extension PullRequest {
    var systemImage: String {
        switch state {
        case .open: checks == .failing ? "xmark.circle" : "arrow.triangle.pull"
        case .draft: "circle.dashed"
        case .merged: "arrow.triangle.merge"
        case .closed: "xmark.circle"
        }
    }

    var stateName: String {
        switch state {
        case .open: "Open"
        case .draft: "Draft"
        case .merged: "Merged"
        case .closed: "Closed"
        }
    }

    /// What needs the user, for the toolbar and the sidebar.
    var summary: String {
        switch state {
        case .merged, .closed: stateName
        case .open, .draft:
            switch checks {
            case .failing: "Checks failing"
            case .pending: "Checks running"
            case .passing, nil: review == .approved ? "Approved" : stateName
            }
        }
    }

    /// The state, checks and review, for a menu item's subtitle.
    var detail: String {
        var parts = [stateName]
        if state == .open || state == .draft {
            switch checks {
            case .passing: parts.append("Checks passed")
            case .failing: parts.append("Checks failing")
            case .pending: parts.append("Checks running")
            case nil: break
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

/// The state of a task's most pressing pull request, for its sidebar row.
/// Only failing checks and merges are tinted; they're what call for action.
struct PullRequestIndicator: View {
    let pullRequest: PullRequest

    var body: some View {
        Image(systemName: pullRequest.systemImage)
            .foregroundStyle(tint)
            .help("#\(pullRequest.number) \(pullRequest.summary)")
    }

    private var tint: Color {
        switch (pullRequest.state, pullRequest.checks) {
        case (.merged, _): .purple
        case (.open, .failing), (.draft, .failing): .red
        default: .secondary
        }
    }
}
