import SwiftUI

struct GitBranchListSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
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
                                    .contextMenu { GitBranchMenu(branch: branch, model: model, onCompare: compare) }
                                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                        if model.unavailableReason(for: .deleteBranch(branch)) == nil {
                                            Button("Delete", systemImage: "trash", role: .destructive) {
                                                Task { await model.request(.deleteBranch(branch)) }
                                            }
                                        }
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
                                    .contextMenu {
                                        if let branch = model.listing.branch(for: worktree) {
                                            GitBranchMenu(branch: branch, model: model, onCompare: compare)
                                        }
                                        if !worktree.isCurrent {
                                            if worktree.branch != nil {
                                                Button("Convert to Branch", systemImage: "arrow.triangle.branch") {
                                                    Task { await model.request(.convertWorktree(worktree)) }
                                                }
                                                .disabled(model.unavailableReason(for: .convertWorktree(worktree)) != nil)
                                                .help(model.unavailableReason(for: .convertWorktree(worktree))
                                                      ?? "Keep this branch in the main checkout and remove its worktree folder")
                                            }
                                            Button("Delete", systemImage: "trash", role: .destructive) {
                                                Task { await model.request(.deleteWorktree(worktree)) }
                                            }
                                            .disabled(model.unavailableReason(for: .deleteWorktree(worktree)) != nil)
                                            .help(model.unavailableReason(for: .deleteWorktree(worktree))
                                                  ?? "Delete the worktree folder and its local branch")
                                        }
                                    }
                                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                        if model.unavailableReason(for: .deleteWorktree(worktree)) == nil {
                                            Button("Delete", systemImage: "trash", role: .destructive) {
                                                Task { await model.request(.deleteWorktree(worktree)) }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        if !model.listing.remoteBranches.isEmpty {
                            Section("Remote") {
                                ForEach(model.listing.remoteBranches) { branch in
                                    GitBranchRow(name: branch.name, icon: "cloud", isCurrent: false,
                                                 isMerged: branch.isMergedIntoDefaultBranch)
                                    .contextMenu { GitBranchMenu(branch: branch, model: model, onCompare: compare) }
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
        .task(id: state.model.snapshots) { await model.load() }
        .alert(model.pendingAction?.title ?? "Confirm", isPresented: $model.isConfirming, presenting: model.pendingAction) { action in
            Button(action.buttonTitle, role: action.isDestructive ? .destructive : .confirm) {
                Task { await model.confirm(action) }
            }
            Button("Cancel", role: .cancel) { model.isConfirming = false }
        } message: { action in
            Text(action.message)
        }
        .alert("Git Operation Failed", isPresented: $model.isShowingActionError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.actionError ?? "")
        }
    }

    private func compare(_ branch: GitBranchInfo) {
        guard let item = model.comparison(for: branch) else { return }
        openWindow(value: item)
        dismiss()
    }
}
