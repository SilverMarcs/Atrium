import AtriumProtocol
import SwiftUI

struct SourceControlChangesList: View {
    let source: SourceControl
    let onCommit: () -> Void
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
                        Button("Push to Remote", systemImage: "arrow.up") { Task { await source.push(status) } }
                    }
                }
            }

            if let status, !status.stagedFiles.isEmpty {
                Section {
                    if isStagedExpanded {
                        ForEach(status.stagedFiles) { file in
                            SourceControlFileRow(source: source, status: status, file: file, isStaged: true)
                        }
                    }
                } header: {
                    SourceControlSectionHeader(title: "Staged Changes", systemImage: "checkmark.circle", isExpanded: $isStagedExpanded) {
                        Button("Commit", systemImage: "checkmark", action: onCommit)
                        Button("Unstage All", systemImage: "tray.and.arrow.up") {
                            Task { await source.unstage(status.stagedFiles, in: status) }
                        }
                    }
                }
            }

            if let status, !status.unstagedFiles.isEmpty {
                Section {
                    if isChangesExpanded {
                        ForEach(status.unstagedFiles) { file in
                            SourceControlFileRow(source: source, status: status, file: file, isStaged: false)
                        }
                    }
                } header: {
                    SourceControlSectionHeader(title: "Changes", systemImage: "circle.dashed", isExpanded: $isChangesExpanded) {
                        Button("Stage All", systemImage: "tray.and.arrow.down") {
                            Task { await source.stage(status.unstagedFiles, in: status) }
                        }
                        Button("Discard All", systemImage: "arrow.uturn.backward", role: .destructive) {
                            source.prompt = .discard(nil, status)
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
