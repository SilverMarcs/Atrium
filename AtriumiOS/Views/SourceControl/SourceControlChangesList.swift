import SwiftUI

struct SourceControlChangesList: View {
    @Environment(CompanionClient.self) private var client
    let workspaceID: UUID
    /// Nil until the host has sent the repository's status.
    let status: WireGitStatus?
    let onDiscard: (SourceControlDiscard) -> Void
    @State private var isUnpushedExpanded = true
    @State private var isStagedExpanded = true
    @State private var isChangesExpanded = true

    var body: some View {
        List {
            if let status, !status.unpushedCommits.isEmpty {
                Section {
                    if isUnpushedExpanded {
                        ForEach(status.unpushedCommits) { commit in
                            Label {
                                Text(commit.message)
                                    .lineLimit(1)
                            } icon: {
                                Image(systemName: "circle.fill")
                                    .foregroundStyle(.tint)
                            }
                        }
                    }
                } header: {
                    SourceControlSectionHeader(title: "Unpushed Commits", systemImage: "arrow.up.circle", isExpanded: $isUnpushedExpanded) {
                        Button("Push to Remote", systemImage: "arrow.up") { send(.push) }
                    }
                }
            }

            if let status, !status.stagedFiles.isEmpty {
                Section {
                    if isStagedExpanded {
                        ForEach(status.stagedFiles) { file in
                            SourceControlFileRow(workspaceID: workspaceID, file: file, isStaged: true, onDiscard: nil)
                        }
                    }
                } header: {
                    SourceControlSectionHeader(title: "Staged Changes", systemImage: "checkmark.circle", isExpanded: $isStagedExpanded) {
                        Button("Unstage All", systemImage: "tray.and.arrow.up") { send(.unstageAll) }
                    }
                }
            }

            if let status, !status.unstagedFiles.isEmpty {
                Section {
                    if isChangesExpanded {
                        ForEach(status.unstagedFiles) { file in
                            SourceControlFileRow(workspaceID: workspaceID, file: file, isStaged: false) {
                                onDiscard(SourceControlDiscard(paths: [file.path]))
                            }
                        }
                    }
                } header: {
                    SourceControlSectionHeader(title: "Changes", systemImage: "circle.dashed", isExpanded: $isChangesExpanded) {
                        Button("Stage All", systemImage: "tray.and.arrow.down") { send(.stageAll) }
                        Button("Discard All", systemImage: "arrow.uturn.backward", role: .destructive) {
                            onDiscard(SourceControlDiscard(paths: nil))
                        }
                    }
                }
            }
        }
        // .listStyle(.sidebar)
        .overlay {
            if let status {
                if !status.hasRepository {
                    ContentUnavailableView(
                        "No Repository",
                        systemImage: "arrow.triangle.branch",
                        description: Text("This project folder isn’t a Git repository.")
                    )
                } else if status.unpushedCommits.isEmpty && status.stagedFiles.isEmpty && status.unstagedFiles.isEmpty {
                    ContentUnavailableView("No Changes", systemImage: "checkmark.circle", description: Text("The working tree is clean."))
                }
            } else {
                ProgressView()
                    .controlSize(.large)
            }
        }
    }

    private func send(_ action: CompanionGitAction) {
        client.send(.git(workspaceID: workspaceID, action: action))
    }
}
