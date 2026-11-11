import AtriumProtocol
import SwiftUI

struct GitInspectorView: View {
    @Bindable var state: GitInspectorState

    private var snapshot: GitRepositoryStatus? { state.currentSnapshot }

    private var hasRepository: Bool {
        state.model.repositories?.isEmpty == false
    }

    var body: some View {
        // Sheets and alerts hang off this stable container: the status goes
        // briefly missing while another checkout's loads, and removing the
        // view presenting a sheet or alert mid-presentation crashes AppKit.
        Group {
            if hasRepository {
                repositoryView
            } else if state.model.repositories == nil {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                initializeView
            }
        }
        .sourceControlAlerts(state.model)
        .alert("Stash All Changes", isPresented: $state.showStashAlert) {
            TextField("Stash name", text: $state.stashMessage)
            Button("Stash") {
                state.confirmStashAll()
            }
            Button("Cancel", role: .cancel) { state.stashMessage = "" }
        } message: {
            Text("Stash all staged, unstaged, and untracked changes.")
        }
        .sheet(isPresented: $state.showSyncWithBranchSheet) {
            SyncWithBranchSheet(state: state)
        }
        .sheet(isPresented: $state.showCommitLogSheet) {
            GitCommitLogSheet(state: state)
        }
        .sheet(isPresented: Binding(
            get: { state.branchListSnapshot != nil },
            set: { if !$0 { state.branchListSnapshot = nil } }
        )) {
            if let snapshot = state.branchListSnapshot {
                GitBranchListSheet(snapshot: snapshot, state: state)
            }
        }
        .sheet(isPresented: $state.showStashListSheet) {
            GitStashListSheet(state: state)
        }
        .alert("Undo Last Commit?", isPresented: $state.showUndoLastCommitAlert) {
            Button("Undo", role: .confirm) {
                state.undoLastCommit()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will undo the last commit and return its changes to your working directory.")
        }
        .alert("Rename Commit", isPresented: $state.showRenameCommitAlert) {
            TextField("Commit message", text: $state.renameCommitMessage)
            Button("Rename") {
                state.renameLastCommit()
            }
            Button("Cancel", role: .cancel) { state.renameCommitMessage = "" }
        } message: {
            Text("Enter a new message for the latest commit.")
        }
        .alert("Cannot Apply Stash", isPresented: $state.showStashConflictAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The stash cannot be applied cleanly because it conflicts with your current changes. Commit or discard your changes first, then try again.")
        }
        .alert("New Branch", isPresented: $state.showNewBranchSheet) {
            TextField("Branch name", text: $state.newBranchName)
            Button("Create") {
                state.createBranch(named: state.newBranchName)
            }
            Button("Cancel", role: .cancel) { state.newBranchName = "" }
        } message: {
            Text("Create a new branch from \"\(snapshot?.branchName ?? "HEAD")\"")
        }
    }

    private var initializeView: some View {
        ContentUnavailableView {
            Label("No Repository", systemImage: "arrow.triangle.branch")
        } description: {
            Text("This folder is not a Git repository.")
        } actions: {
            Button("Initialize Repository") {
                Task { await state.model.initializeRepository() }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var repositoryView: some View {
        GitInspectorChangesList(state: state)
        .safeAreaBar(edge: .top) {
            VStack(spacing: 8) {
                GitInspectorBranchBar(state: state)
                GitInspectorCommitArea(state: state)
                    .padding(.horizontal, 5)
            }
            .padding(.horizontal, 8)
            .padding(.top, 13)
        }
        .safeAreaBar(edge: .bottom) {
            VStack {
                if let banner = activeBanner {
                    bannerView(banner)
                        .transition(.move(edge: .bottom))
                }
                if (state.model.repositories?.count ?? 0) > 1 {
                    InspectorRepositoryPicker(project: state.project)
                }
            }
            .padding()
            .animation(.easeInOut(duration: 0.2), value: activeBanner)
        }
        .task(id: snapshot?.branchName) {
            guard let snapshot, snapshot.branchName != nil else { return }
            await state.model.fetchIfStale(snapshot)
        }
    }

    // MARK: - Banner

    private enum BannerKind: Equatable {
        case success(String)
    }

    private var activeBanner: BannerKind? {
        if let success = state.model.successMessage { return .success(success) }
        return nil
    }

    @ViewBuilder
    private func bannerView(_ banner: BannerKind) -> some View {
        let message: String = switch banner {
        case .success(let msg): msg
        }
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text(message)
                .lineLimit(3)
            Spacer()
            Button {
                dismissBanner(banner)
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
        }
        .font(.caption)
        .padding(8)
        .padding(.horizontal, 2)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
        .task(id: banner) {
            try? await Task.sleep(for: .seconds(3))
            dismissBanner(banner)
        }
    }

    private func dismissBanner(_ banner: BannerKind) {
        switch banner {
        case .success(let msg):
            if state.model.successMessage == msg { state.model.successMessage = nil }
        }
    }
}
