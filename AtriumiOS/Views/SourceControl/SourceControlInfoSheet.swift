import SwiftUI

/// Surfaces repo state that the main list doesn't already show: tracking
/// status, behind/ahead counts, and totals — useful for deciding whether
/// to pull/push without scrolling the change list.
struct SourceControlInfoSheet: View {
    @Environment(CompanionClient.self) private var client
    @Environment(\.dismiss) private var dismiss
    let workspaceId: UUID

    private var status: WireGitStatus? { client.gitStatus }

    var body: some View {
        NavigationStack {
            Form {
                if let status {
                    Section("Branch") {
                        LabeledContent("Current") {
                            Text(status.branchName ?? "—")
                                .foregroundStyle(.secondary)
                        }
                        LabeledContent("Local Branches") {
                            Text("\(status.localBranches.count)")
                                .foregroundStyle(.secondary)
                        }
                    }

                    Section("Remote") {
                        LabeledContent("Tracking") {
                            Text(status.hasTrackingBranch ? "Yes" : "Not Published")
                                .foregroundStyle(.secondary)
                        }
                        LabeledContent("Ahead") {
                            Text("\(status.unpushedCommits.count)")
                                .foregroundStyle(.secondary)
                        }
                        LabeledContent("Behind") {
                            Text("\(status.remoteAheadCount)")
                                .foregroundStyle(.secondary)
                        }
                    }

                    Section("Working Tree") {
                        LabeledContent("Staged") {
                            Text("\(status.stagedFiles.count)")
                                .foregroundStyle(.secondary)
                        }
                        LabeledContent("Unstaged") {
                            Text("\(status.unstagedFiles.count)")
                                .foregroundStyle(.secondary)
                        }
                    }
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
