import AtriumProtocol
import SwiftUI

struct SourceControlChangesList: View {
    let source: SourceControl
    let onCommit: () -> Void
    let onDiscard: (SourceControlDiscard) -> Void
    @State private var isUnpushedExpanded = true
    @State private var isStagedExpanded = true
    @State private var isChangesExpanded = true

    var body: some View {
        let status = source.status
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
                        Button("Push to Remote", systemImage: "arrow.up") { source.send(.push(branch: status.branchName)) }
                    }
                }
            }

            if let status, !status.stagedFiles.isEmpty {
                Section {
                    if isStagedExpanded {
                        ForEach(status.stagedFiles) { file in
                            SourceControlFileRow(source: source, file: file, isStaged: true, onDiscard: nil)
                        }
                    }
                } header: {
                    SourceControlSectionHeader(title: "Staged Changes", systemImage: "checkmark.circle", isExpanded: $isStagedExpanded) {
                        Button("Commit", systemImage: "checkmark", action: onCommit)
                        Button("Unstage All", systemImage: "tray.and.arrow.up") {
                            source.send(.unstage(paths: status.stagedFiles.map(\.repositoryRelativePath)))
                        }
                    }
                }
            }

            if let status, !status.unstagedFiles.isEmpty {
                Section {
                    if isChangesExpanded {
                        ForEach(status.unstagedFiles) { file in
                            SourceControlFileRow(source: source, file: file, isStaged: false) {
                                onDiscard(SourceControlDiscard(files: [file]))
                            }
                        }
                    }
                } header: {
                    SourceControlSectionHeader(title: "Changes", systemImage: "circle.dashed", isExpanded: $isChangesExpanded) {
                        Button("Stage All", systemImage: "tray.and.arrow.down") {
                            source.send(.stage(paths: status.unstagedFiles.map(\.repositoryRelativePath)))
                        }
                        Button("Discard All", systemImage: "arrow.uturn.backward", role: .destructive) {
                            onDiscard(SourceControlDiscard(files: nil))
                        }
                    }
                }
            }
        }
        .overlay {
            if let repositories = source.repositories {
                if let status, status.unpushedCommits.isEmpty && status.stagedFiles.isEmpty && status.unstagedFiles.isEmpty {
                    ContentUnavailableView("No Changes", systemImage: "checkmark.circle", description: Text("The working tree is clean."))
                } else if repositories.isEmpty {
                    ContentUnavailableView(
                        "No Repository",
                        systemImage: "arrow.triangle.branch",
                        description: Text("This project folder isn’t a Git repository.")
                    )
                }
            } else {
                ProgressView()
                    .controlSize(.large)
            }
        }
    }

}
