import SwiftUI

struct GitBranchListSheet: View {
    let directoryURL: URL
    @Bindable var state: GitInspectorState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @State private var branches: [GitBranchInfo] = []
    @State private var isLoading = true

    private var snapshot: GitRepositoryStatusSnapshot? { state.currentSnapshot }

    private var localBranches: [GitBranchInfo] { branches.filter { !$0.isRemote } }
    private var remoteBranches: [GitBranchInfo] { branches.filter { $0.isRemote } }
    private var currentBranchName: String? { branches.first(where: { $0.isCurrent })?.name }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if branches.isEmpty {
                    ContentUnavailableView(
                        "No Branches",
                        systemImage: "arrow.triangle.branch",
                        description: Text("This repository has no local branches.")
                    )
                } else {
                    List {
                        Section("Local") {
                            ForEach(localBranches) { branch in
                                branchRow(branch)
                                    .contextMenu {
                                        compareMenu(for: branch)
                                        if !branch.isCurrent {
                                            Divider()
                                            deleteButton(branch)
                                        }
                                    }
                                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                        if !branch.isCurrent {
                                            deleteButton(branch)
                                        }
                                    }
                            }
                        }
                        if !remoteBranches.isEmpty {
                            Section("Remote") {
                                ForEach(remoteBranches) { branch in
                                    branchRow(branch)
                                        .contextMenu { compareMenu(for: branch) }
                                }
                            }
                        }
                    }
                    .listStyle(.inset)
                }
            }
            .navigationTitle("Branches")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .frame(width: 420, height: 440)
        .task { await load() }
        .alert("Delete Unmerged Branch?", isPresented: deleteAlertBinding) {
            Button("Delete", role: .confirm) {
                guard let branch = state.branchPendingDelete else { return }
                state.branchPendingDelete = nil
                Task {
                    guard let snap = state.currentSnapshot else { return }
                    _ = await state.model.deleteBranch(branch.name, force: true, snapshot: snap)
                    await load()
                    await state.refresh(directoryURL: directoryURL)
                }
            }
            Button("Cancel", role: .cancel) { state.branchPendingDelete = nil }
        } message: {
            Text("\"\(state.branchPendingDelete?.name ?? "")\" is not fully merged into the current branch. Deleting it may discard commits permanently.")
        }
        .alert("Sync Failure", isPresented: errorAlertBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(state.model.errorMessage ?? "")
        }
    }

    private var deleteAlertBinding: Binding<Bool> {
        Binding(
            get: { state.branchPendingDelete != nil },
            set: { if !$0 { state.branchPendingDelete = nil } }
        )
    }

    private var errorAlertBinding: Binding<Bool> {
        Binding(
            get: { state.model.errorMessage != nil },
            set: { if !$0 { state.model.errorMessage = nil } }
        )
    }

    @ViewBuilder
    private func compareMenu(for branch: GitBranchInfo) -> some View {
        if !branch.isCurrent, let head = currentBranchName {
            if branch.upstream != nil {
                Button {
                    syncWithUpstream(for: branch)
                } label: {
                    Label("Sync with Upstream", systemImage: "arrow.triangle.2.circlepath")
                }
                Divider()
            }
            Button {
                openCompare(base: branch.name, head: head)
            } label: {
                Label("Compare with Current Branch…", systemImage: "arrow.left.arrow.right")
            }
        }
    }

    private func syncWithUpstream(for branch: GitBranchInfo) {
        guard let snapshot else { return }
        Task {
            await state.model.syncBranchWithUpstream(branch, snapshot: snapshot)
            await load()
            await state.refresh(directoryURL: directoryURL)
        }
    }

    private func openCompare(base: String, head: String) {
        guard let snapshot else { return }
        openWindow(value: GitCommitDiffSheetItem(
            range: GitBranchRange(base: base, head: head),
            message: "Comparing \(head) against \(base)",
            repositoryRootURL: snapshot.repositoryRootURL
        ))
        dismiss()
    }

    @ViewBuilder
    private func branchRow(_ branch: GitBranchInfo) -> some View {
        HStack(spacing: 8) {
            Image(systemName: rowIcon(for: branch))
                .foregroundStyle(branch.isCurrent ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(branch.name)
                    .font(.body)
                    .lineLimit(1)
                if let upstream = branch.upstream {
                    Text(upstream)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if branch.isMerged && !branch.isCurrent {
                Text("Merged")
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.background.secondary, in: Capsule())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func rowIcon(for branch: GitBranchInfo) -> String {
        if branch.isCurrent { return "checkmark.circle.fill" }
        if branch.isRemote { return "cloud" }
        return "arrow.triangle.branch"
    }

    private func handleDelete(_ branch: GitBranchInfo) {
        guard let snapshot, !branch.isCurrent else { return }
        if branch.isMerged {
            Task {
                _ = await state.model.deleteBranch(branch.name, force: false, snapshot: snapshot)
                await load()
                await state.refresh(directoryURL: directoryURL)
            }
        } else {
            state.branchPendingDelete = branch
        }
    }

    private func deleteButton(_ branch: GitBranchInfo) -> some View {
        Button(role: .destructive) {
            handleDelete(branch)
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    private func load() async {
        guard let snapshot else {
            isLoading = false
            return
        }
        isLoading = branches.isEmpty
        branches = await state.model.branches(snapshot: snapshot)
        isLoading = false
    }
}
