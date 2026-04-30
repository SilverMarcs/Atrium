import SwiftUI

/// iOS source control surface for one workspace. Mirrors the host's three
/// sections (unpushed commits, staged changes, working changes) but skips
/// any section that's empty so the screen never shows an empty stub. Branch
/// picker lives in the title menu; advanced operations (push/pull/fetch,
/// new branch) sit on the bottom toolbar alongside search and the
/// workspace tools menu, mirroring the chat detail screen's shape.
struct SourceControlScreen: View {
    @Environment(CompanionClient.self) private var client
    let workspaceId: UUID

    @State private var commitMessage = ""
    @State private var isCommitFocused = false
    @State private var showingNewBranch = false
    @State private var newBranchName = ""
    @State private var showingInfo = false
    @State private var pendingDiscard: PendingDiscard?

    private struct PendingDiscard: Identifiable {
        let id = UUID()
        var files: [WireGitFile]?
        var all: Bool
    }

    private var status: WireGitStatus? { client.gitStatus }

    private var canCommit: Bool {
        !(status?.stagedFiles.isEmpty ?? true)
    }

    var body: some View {
        Group {
            if let status, status.hasRepository {
                contentList(status: status)
            } else if status == nil {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(
                    "No Repository",
                    systemImage: "arrow.triangle.branch",
                    description: Text("This workspace folder is not a Git repository.")
                )
            }
        }
        .toolbarTitleDisplayMode(.inline)
        .refreshable {
            client.gitRefresh(workspaceId: workspaceId)
        }
        .navigationTitle(status?.branchName ?? "Source Control")
        .toolbarTitleMenu {
            if let status {
                ForEach(status.localBranches, id: \.self) { branch in
                    Button {
                        client.gitSwitchBranch(workspaceId: workspaceId, branch: branch)
                    } label: {
                        if branch == status.branchName {
                            Label(branch, systemImage: "checkmark")
                        } else {
                            Text(branch)
                        }
                    }
                }
            }
        }
        .alert("New Branch", isPresented: $showingNewBranch) {
            TextField("Branch name", text: $newBranchName)
            Button("Create") {
                let trimmed = newBranchName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                client.gitCreateBranch(workspaceId: workspaceId, name: trimmed)
                newBranchName = ""
            }
            Button("Cancel", role: .cancel) { newBranchName = "" }
        } message: {
            Text("Create a new branch from \"\(status?.branchName ?? "HEAD")\".")
        }
        .alert(
            "Discard Changes?",
            isPresented: Binding(
                get: { pendingDiscard != nil },
                set: { if !$0 { pendingDiscard = nil } }
            ),
            presenting: pendingDiscard
        ) { target in
            Button("Discard", role: .confirm) {
                if target.all {
                    client.gitDiscardAll(workspaceId: workspaceId)
                } else if let files = target.files {
                    client.gitDiscard(workspaceId: workspaceId, files: files)
                }
                pendingDiscard = nil
            }
            Button("Cancel", role: .cancel) { pendingDiscard = nil }
        } message: { target in
            if target.all {
                Text("This will discard all working-tree changes. Cannot be undone.")
            } else if let files = target.files, files.count == 1 {
                Text("This will discard changes to \"\(files[0].path)\". Cannot be undone.")
            } else if let files = target.files {
                Text("This will discard changes to \(files.count) files. Cannot be undone.")
            } else {
                Text("")
            }
        }
        .task(id: workspaceId) {
            client.gitSubscribe(workspaceId: workspaceId)
        }
        .searchable(
            text: $commitMessage,
            isPresented: $isCommitFocused,
            prompt: "Commit message"
        )
        .searchPresentationToolbarBehavior(.avoidHidingContent)
        .onSubmit(of: .search) { commit() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingInfo = true
                } label: {
                    Label("Info", systemImage: "info")
                }
                .disabled(!(status?.hasRepository ?? false))
            }
            ToolbarItem(placement: .bottomBar) {
                NavigationLink(value: Route.commands(workspaceId)) {
                    Label("Commands", systemImage: "terminal")
                }
            }
            ToolbarSpacer(.fixed, placement: .bottomBar)
            DefaultToolbarItem(kind: .search, placement: .bottomBar)
            if status?.hasRepository == true {
                ToolbarSpacer(.fixed, placement: .bottomBar)
                ToolbarItem(placement: .bottomBar) {
                    actionsMenu
                }
            }
        }
        .sheet(isPresented: $showingInfo) {
            SourceControlInfoSheet(workspaceId: workspaceId)
        }
    }

    @ViewBuilder
    private func contentList(status: WireGitStatus) -> some View {
        List {
            if !status.unpushedCommits.isEmpty {
                Section {
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
                    SourceControlSectionHeader(
                        title: "Unpushed Commits",
                        systemImage: "arrow.up.circle"
                    ) {
                        Button {
                            client.gitPush(workspaceId: workspaceId)
                        } label: {
                            Label("Push to Remote", systemImage: "arrow.up")
                        }
                    }
                }
            }

            if !status.stagedFiles.isEmpty {
                Section {
                    ForEach(status.stagedFiles) { file in
                        SourceControlFileRow(
                            workspaceId: workspaceId,
                            file: file,
                            stage: "staged",
                            onDiscardConfirm: nil
                        )
                    }
                } header: {
                    SourceControlSectionHeader(
                        title: "Staged Changes",
                        systemImage: "checkmark.circle"
                    ) {
                        Button {
                            client.gitUnstageAll(workspaceId: workspaceId)
                        } label: {
                            Label("Unstage All", systemImage: "tray.and.arrow.up")
                        }
                    }
                }
            }

            if !status.unstagedFiles.isEmpty {
                Section {
                    ForEach(status.unstagedFiles) { file in
                        SourceControlFileRow(
                            workspaceId: workspaceId,
                            file: file,
                            stage: "unstaged",
                            onDiscardConfirm: { files in
                                pendingDiscard = PendingDiscard(files: files, all: false)
                            }
                        )
                    }
                } header: {
                    SourceControlSectionHeader(
                        title: "Changes",
                        systemImage: "circle.dashed"
                    ) {
                        Button {
                            client.gitStageAll(workspaceId: workspaceId)
                        } label: {
                            Label("Stage All", systemImage: "tray.and.arrow.down")
                        }
                        Button(role: .destructive) {
                            pendingDiscard = PendingDiscard(files: nil, all: true)
                        } label: {
                            Label("Discard All", systemImage: "arrow.uturn.backward")
                        }
                    }
                }
            }

        }
    }

    private func commit() {
        guard canCommit else { return }
        let trimmed = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        client.gitCommit(workspaceId: workspaceId, message: trimmed)
        commitMessage = ""
        isCommitFocused = false
    }

    @ViewBuilder
    private var actionsMenu: some View {
        Menu {
            Button {
                client.gitPush(workspaceId: workspaceId)
            } label: {
                Label("Push", systemImage: "arrow.up")
            }
            .disabled((status?.unpushedCommits.isEmpty ?? true) && (status?.hasTrackingBranch ?? true))

            Button {
                client.gitPull(workspaceId: workspaceId)
            } label: {
                Label("Pull", systemImage: "arrow.down")
            }
            .disabled(!(status?.hasTrackingBranch ?? false))

            Button {
                client.gitFetch(workspaceId: workspaceId)
            } label: {
                Label("Fetch", systemImage: "arrow.clockwise")
            }

            Divider()

            Button {
                showingNewBranch = true
            } label: {
                Label("New Branch", systemImage: "plus")
            }
        } label: {
            Image(systemName: "point.topleft.down.curvedto.point.bottomright.up.fill")
        }
    }
}
