import SwiftUI

/// Tracking and counts that help decide whether to pull or push.
struct SourceControlInfoSheet: View {
    @Environment(\.dismiss) private var dismiss
    let status: WireGitStatus

    var body: some View {
        NavigationStack {
            Form {
                Section("Branch") {
                    LabeledContent("Current", value: status.branchName ?? "—")
                    LabeledContent("Local Branches", value: status.localBranches.count, format: .number)
                }
                Section("Remote") {
                    LabeledContent("Tracking", value: status.hasTrackingBranch ? "Yes" : "Not Published")
                    LabeledContent("Ahead", value: status.unpushedCommits.count, format: .number)
                    LabeledContent("Behind", value: status.remoteAheadCount, format: .number)
                }
                Section("Working Tree") {
                    LabeledContent("Staged", value: status.stagedFiles.count, format: .number)
                    LabeledContent("Unstaged", value: status.unstagedFiles.count, format: .number)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Repository Info")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .close) { dismiss() }
                }
            }
        }
    }
}
