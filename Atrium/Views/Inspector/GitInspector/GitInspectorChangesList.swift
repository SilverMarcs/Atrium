import SwiftUI

struct GitInspectorChangesList: View {
    let directoryURL: URL
    @Bindable var state: GitInspectorState
    var onShowInFileTree: ((URL) -> Void)?

    @Environment(EditorPanel.self) private var editorPanel

    private var snapshot: GitRepositoryStatusSnapshot? { state.currentSnapshot }

    var body: some View {
        List(selection: $state.selectedFileID) {
            if let snapshot {
                if !snapshot.unpushedCommits.isEmpty {
                    DisclosureGroup(isExpanded: $state.unpushedExpanded) {
                        ForEach(Array(snapshot.unpushedCommits.enumerated()), id: \.element.id) { index, commit in
                            Label {
                                Text(commit.message)
                                    .lineLimit(1)
                            } icon: {
                                Image(systemName: "circle.fill")
                                    .foregroundStyle(.accent)
                            }
                            .font(.subheadline)
                            .contextMenu {
                                GitCommitContextMenu(
                                    commit: commit,
                                    isLatest: index == 0,
                                    isDirty: snapshot.isDirty,
                                    onRename: {
                                        state.renameCommitMessage = commit.message
                                        state.showRenameCommitAlert = true
                                    },
                                    onUndo: {
                                        state.showUndoLastCommitAlert = true
                                    }
                                )
                            }
                            .listRowSeparator(.hidden)
                        }
                    } label: {
                        sectionHeader(
                            title: "Unpushed Commits",
                            systemImage: "arrow.up.circle",
                            isExpanded: $state.unpushedExpanded
                        )
                        .contextMenu {
                            Button { handleAction(.push(snapshot)) } label: {
                                Label("Push to Remote", systemImage: "arrow.up")
                            }
                            Divider()
                            Button {
                                state.showUndoLastCommitAlert = true
                            } label: {
                                Label("Undo Last Commit", systemImage: "arrow.uturn.backward")
                            }
                            .disabled(snapshot.isDirty)
                        }
                    }
                    .listRowSeparator(.hidden)
                }

                if !snapshot.stagedFiles.isEmpty {
                    DisclosureGroup(isExpanded: $state.stagedExpanded) {
                        fileRows(snapshot.stagedFiles, staged: true, snapshot: snapshot)
                    } label: {
                        sectionHeader(
                            title: "Staged Changes",
                            systemImage: "checkmark.circle",
                            isExpanded: $state.stagedExpanded
                        )
                        .contextMenu { GitRepoContextMenu(snapshot: snapshot, onAction: handleAction) }
                    }
                    .listRowSeparator(.hidden)
                }

                if !snapshot.unstagedFiles.isEmpty {
                    DisclosureGroup(isExpanded: $state.unstagedExpanded) {
                        fileRows(snapshot.unstagedFiles, staged: false, snapshot: snapshot)
                    } label: {
                        sectionHeader(
                            title: "Changes",
                            systemImage: "circle.dashed",
                            isExpanded: $state.unstagedExpanded
                        )
                        .contextMenu { GitRepoContextMenu(snapshot: snapshot, onAction: handleAction) }
                    }
                    .listRowSeparator(.hidden)
                }
            }
        }
        .contextMenu(forSelectionType: String.self) { items in
            if let id = items.first, let (file, stage, snap) = resolveFile(id: id) {
                let staged = stage == .staged
                GitFileContextMenu(files: [file], staged: staged, snapshot: snap, onAction: handleAction)
            }
        } primaryAction: { items in
            for id in items {
                if let (file, _, _) = resolveFile(id: id) {
                    editorPanel.openFile(file.fileURL)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .onChange(of: state.selectedFileID) { _, newID in
            guard let id = newID,
                  let (file, stage, snap) = resolveFile(id: id) else { return }
            editorPanel.openDiff(file.fileURL, in: snap.repositoryRootURL, stage: stage, kind: file.kind)
        }
    }

    // MARK: - Section Header

    @ViewBuilder
    private func sectionHeader(title: String, systemImage: String, isExpanded: Binding<Bool>) -> some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(.accent)
        }
        .font(.subheadline)
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation {
                isExpanded.wrappedValue.toggle()
            }
        }
    }

    // MARK: - Rows

    private struct GitFileRow: Identifiable, Hashable {
        let id: String
        let file: GitChangedFile
    }

    @ViewBuilder
    private func fileRows(_ files: [GitChangedFile], staged: Bool, snapshot: GitRepositoryStatusSnapshot) -> some View {
        let prefix = staged ? "staged" : "unstaged"
        let rows = files.map { GitFileRow(id: "\(prefix):\($0.repositoryRelativePath)", file: $0) }
        ForEach(rows) { row in
            FileLabel(name: row.file.fileURL.lastPathComponent, icon: row.file.fileURL.fileIcon) {
                GitStatusBadge(kind: row.file.kind, staged: staged)
                    .overlay {
                        Menu {
                            GitFileContextMenu(files: [row.file], staged: staged, snapshot: snapshot, onAction: handleAction)
                        } label: {
                            Color.clear.contentShape(Rectangle())
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                    }
            }
            .tag(row.id)
        }
        .listRowSeparator(.hidden)
    }

    // MARK: - Bindings & Helpers

    private func resolveFile(id: String) -> (GitChangedFile, GitDiffStage, GitRepositoryStatusSnapshot)? {
        guard let snapshot else { return nil }

        let staged = id.hasPrefix("staged:")
        let path = String(id.drop(while: { $0 != ":" }).dropFirst())
        let files = staged ? snapshot.stagedFiles : snapshot.unstagedFiles
        if let file = files.first(where: { $0.repositoryRelativePath == path }) {
            return (file, staged ? .staged : .unstaged, snapshot)
        }
        return nil
    }

    // MARK: - Action Dispatch

    private func handleAction(_ action: GitAction) {
        switch action {
        case .showInFileTree(let url):
            onShowInFileTree?(url)
        case .commit:
            // Commit is handled by the commit area; ignore from list-side menus.
            break
        case .push(let snap) where !snap.hasTrackingBranch:
            state.showPushUpstreamAlert = true
        default:
            state.perform(action, directoryURL: directoryURL)
        }
    }
}
