import AtriumProtocol
import SwiftUI

struct GitBranchListSheet: View {
    @Environment(\.dismiss) private var dismiss
    private let state: GitInspectorState
    @State private var model: GitBranchListModel

    init(snapshot: GitRepositoryStatus, state: GitInspectorState) {
        self.state = state
        _model = State(initialValue: GitBranchListModel(snapshot: snapshot, inspector: state))
    }

    var body: some View {
        NavigationStack {
            Group {
                if model.isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = model.loadError {
                    ContentUnavailableView {
                        Label("Unable to Load Branches", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Retry") { Task { await model.load() } }
                    }
                } else if model.listing.branches.isEmpty && model.listing.linkedWorktrees.isEmpty {
                    ContentUnavailableView("No Branches", systemImage: "arrow.triangle.branch",
                                           description: Text("This repository has no branches or linked worktrees."))
                } else {
                    List {
                        if !model.listing.localBranches.isEmpty {
                            Section("Local") {
                                ForEach(model.listing.localBranches) { branch in
                                    GitBranchRow(name: branch.name, icon: "arrow.triangle.branch",
                                                 isCurrent: branch.isCurrent, isMerged: branch.isMergedIntoDefaultBranch)
                                    .contextMenu { deleteButton(for: .deleteBranch(branch)) }
                                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                        deleteButton(for: .deleteBranch(branch))
                                    }
                                }
                            }
                        }
                        if !model.listing.linkedWorktrees.isEmpty {
                            Section("Worktrees") {
                                ForEach(model.listing.linkedWorktrees) { worktree in
                                    GitBranchRow(name: worktree.branch ?? "Detached · \(worktree.head?.prefix(7) ?? "")",
                                                 subtitle: worktree.path.path(percentEncoded: false), icon: "folder",
                                                 isCurrent: worktree.isCurrent, isMerged: model.listing.isMerged(worktree))
                                    .contextMenu { deleteButton(for: .deleteWorktree(worktree)) }
                                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                        deleteButton(for: .deleteWorktree(worktree))
                                    }
                                }
                            }
                        }
                        if !model.listing.remoteBranches.isEmpty {
                            Section("Remote") {
                                ForEach(model.listing.remoteBranches) { branch in
                                    GitBranchRow(name: branch.name, icon: "cloud", isCurrent: false,
                                                 isMerged: branch.isMergedIntoDefaultBranch)
                                }
                            }
                        }
                    }
                    .listStyle(.inset)
                    .disabled(model.isBusy)
                }
            }
            .navigationTitle("Branches")
            .navigationSubtitle(model.listing.mergeTarget.map { "Merged into \($0)" } ?? "Merge target unavailable")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .frame(width: 420, height: 440)
        .task(id: state.model.repositories) { await model.load() }
        .alert(model.pendingAction?.title ?? "Confirm", isPresented: $model.isConfirming, presenting: model.pendingAction) { action in
            Button("Delete", role: .destructive) {
                Task { await model.confirm(action) }
            }
            Button("Cancel", role: .cancel) { model.isConfirming = false }
        } message: { action in
            Text(action.message)
        }
        .alert("Git Operation Failed", isPresented: $model.isShowingActionError) {
            if let action = model.forceableAction {
                Button("Force Delete", role: .destructive) {
                    Task { await model.forceDelete(action) }
                }
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.actionError ?? "")
        }
    }

    /// Deletes a branch or worktree, or nothing when it can't be deleted.
    @ViewBuilder
    private func deleteButton(for action: GitBranchAction) -> some View {
        if model.unavailableReason(for: action) == nil {
            Button("Delete", systemImage: "trash", role: .destructive) {
                Task { await model.request(action) }
            }
        }
    }
}
