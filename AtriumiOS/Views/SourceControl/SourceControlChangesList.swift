import SwiftUI

struct SourceControlChangesList: View {
    @Environment(CompanionClient.self) private var client
    let workspaceID: UUID
    let status: WireGitStatus
    let onDiscard: (SourceControlDiscard) -> Void
    @State private var isUnpushedExpanded = true
    @State private var isStagedExpanded = true
    @State private var isChangesExpanded = true

    var body: some View {
        List {
            if !status.unpushedCommits.isEmpty {
                Section(isExpanded: $isUnpushedExpanded.animation()) {
                    ForEach(status.unpushedCommits) { commit in
                        Label {
                            Text(commit.message)
                                .lineLimit(1)
                        } icon: {
                            Image(systemName: "circle.fill")
                                .foregroundStyle(.tint)
                        }
                    }
                } header: {
                    SourceControlSectionHeader(title: "Unpushed Commits", systemImage: "arrow.up.circle") {
                        Button("Push to Remote", systemImage: "arrow.up") { send(.push) }
                    }
                }
            }

            if !status.stagedFiles.isEmpty {
                Section(isExpanded: $isStagedExpanded.animation()) {
                    ForEach(status.stagedFiles) { file in
                        SourceControlFileRow(workspaceID: workspaceID, file: file, isStaged: true, onDiscard: nil)
                    }
                } header: {
                    SourceControlSectionHeader(title: "Staged Changes", systemImage: "checkmark.circle") {
                        Button("Unstage All", systemImage: "tray.and.arrow.up") { send(.unstageAll) }
                    }
                }
            }

            if !status.unstagedFiles.isEmpty {
                Section(isExpanded: $isChangesExpanded.animation()) {
                    ForEach(status.unstagedFiles) { file in
                        SourceControlFileRow(workspaceID: workspaceID, file: file, isStaged: false) {
                            onDiscard(SourceControlDiscard(paths: [file.path]))
                        }
                    }
                } header: {
                    SourceControlSectionHeader(title: "Changes", systemImage: "circle.dashed") {
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
            if status.unpushedCommits.isEmpty && status.stagedFiles.isEmpty && status.unstagedFiles.isEmpty {
                ContentUnavailableView("No Changes", systemImage: "checkmark.circle", description: Text("The working tree is clean."))
            }
        }
    }

    private func send(_ action: CompanionGitAction) {
        client.send(.git(workspaceID: workspaceID, action: action))
    }
}
