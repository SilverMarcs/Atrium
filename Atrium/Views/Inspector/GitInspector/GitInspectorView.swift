import SwiftUI

struct GitInspectorView: View {
    let directoryURL: URL
    @Bindable var state: GitInspectorState
    var onShowInFileTree: ((URL) -> Void)?

    private var snapshot: GitRepositoryStatusSnapshot? { state.currentSnapshot }

    private var hasRepository: Bool {
        !state.model.snapshots.isEmpty
    }

    var body: some View {
        if hasRepository {
            repositoryView
        } else if !state.model.hasCompletedInitialScan {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .task(id: directoryURL) {
                    await state.refresh(directoryURL: directoryURL)
                }
        } else {
            initializeView
        }
    }

    private var initializeView: some View {
        ContentUnavailableView {
            Label("No Repository", systemImage: "arrow.triangle.branch")
        } description: {
            Text("This folder is not a Git repository.")
        } actions: {
            Button("Initialize Repository") {
                Task {
                    await state.model.initializeRepository(at: directoryURL)
                    await state.refresh(directoryURL: directoryURL)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: directoryURL) {
            await state.refresh(directoryURL: directoryURL)
        }
        .watchFileSystem(at: directoryURL) {
            Task { await state.refresh(directoryURL: directoryURL) }
        }
    }

    private var repositoryView: some View {
        GitInspectorChangesList(
            directoryURL: directoryURL,
            state: state,
            onShowInFileTree: onShowInFileTree
        )
        .safeAreaBar(edge: .top) {
            VStack(spacing: 8) {
                GitInspectorBranchBar(directoryURL: directoryURL, state: state)
                GitInspectorCommitArea(directoryURL: directoryURL, state: state)
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
                if state.model.snapshots.count > 1 {
                    repoPicker
                }
            }
            .padding()
            .animation(.easeInOut(duration: 0.2), value: activeBanner)
        }
        .task(id: directoryURL) {
            await state.refresh(directoryURL: directoryURL)
            if state.selectedRepoURL == nil {
                state.selectedRepoURL = state.model.snapshots.first?.repositoryRootURL
            }
        }
        .task(id: snapshot?.branchName) {
            guard let snapshot else { return }
            await state.model.fetch(snapshot: snapshot)
            await state.refresh(directoryURL: directoryURL)
        }
        .watchFileSystem(at: directoryURL) {
            Task { await state.refresh(directoryURL: directoryURL) }
        }
        .alert("Discard Changes?", isPresented: discardAlertBinding) {
            Button("Discard", role: .destructive) {
                guard let target = state.discardTarget else { return }
                state.performDiscard(target, directoryURL: directoryURL)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(discardAlertMessage)
        }
        .alert("Stash Changes?", isPresented: stashAlertBinding) {
            Button("Stash & Switch", role: .destructive) {
                state.confirmStashAndSwitch(directoryURL: directoryURL)
            }
            Button("Cancel", role: .cancel) { state.pendingBranchSwitch = nil }
        } message: {
            Text("You have uncommitted changes. Stash all changes (including staged and untracked) before switching branches?")
        }
        .alert("Stash All Changes", isPresented: $state.showStashAlert) {
            TextField("Stash name", text: $state.stashMessage)
            Button("Stash") {
                state.confirmStashAll(directoryURL: directoryURL)
            }
            Button("Cancel", role: .cancel) { state.stashMessage = "" }
        } message: {
            Text("Stash all staged, unstaged, and untracked changes.")
        }
        .alert("Publish Branch?", isPresented: $state.showPushUpstreamAlert) {
            Button("Publish") {
                state.pushSetUpstream(directoryURL: directoryURL)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The branch \"\(snapshot?.branchName ?? "")\" does not exist on the remote. This will create a new branch on the remote and push your commits.")
        }
        .sheet(isPresented: $state.showSyncWithBranchSheet) {
            SyncWithBranchSheet(directoryURL: directoryURL, state: state)
        }
        .sheet(isPresented: $state.showCommitLogSheet) {
            GitCommitLogSheet(state: state)
        }
        .alert("Undo Last Commit?", isPresented: $state.showUndoLastCommitAlert) {
            Button("Undo", role: .destructive) {
                state.undoLastCommit(directoryURL: directoryURL)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will undo the last commit and return its changes to your working directory.")
        }
        .alert("Rename Commit", isPresented: $state.showRenameCommitAlert) {
            TextField("Commit message", text: $state.renameCommitMessage)
            Button("Rename") {
                state.renameLastCommit(directoryURL: directoryURL)
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
                state.createBranch(named: state.newBranchName, directoryURL: directoryURL)
            }
            Button("Cancel", role: .cancel) { state.newBranchName = "" }
        } message: {
            Text("Create a new branch from \"\(snapshot?.branchName ?? "HEAD")\"")
        }
    }

    // MARK: - Repo Picker

    private var repoPicker: some View {
        Picker(selection: $state.selectedRepoURL) {
            ForEach(state.model.snapshots, id: \.repositoryRootURL) { snapshot in
                Label {
                    Text(snapshot.repositoryRootURL.lastPathComponent)
                } icon: {
                    Image(systemName: "arrow.right.arrow.left")
                }
                .lineLimit(1)
                .tag(Optional(snapshot.repositoryRootURL))
            }
        } label: {
            EmptyView()
        }
        .pickerStyle(.menu)
        .controlSize(.large)
        .buttonSizing(.flexible)
    }

    // MARK: - Banner

    private enum BannerKind: Equatable {
        case success(String)
        case error(String)
    }

    private var activeBanner: BannerKind? {
        if let error = state.model.errorMessage { return .error(error) }
        if let success = state.model.successMessage { return .success(success) }
        return nil
    }

    @ViewBuilder
    private func bannerView(_ banner: BannerKind) -> some View {
        let (icon, iconColor, message): (String, Color, String) = switch banner {
        case .error(let msg): ("exclamationmark.triangle.fill", .yellow, msg)
        case .success(let msg): ("checkmark.circle.fill", .green, msg)
        }
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(iconColor)
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
            let seconds: Int = if case .success = banner { 3 } else { 5 }
            try? await Task.sleep(for: .seconds(seconds))
            dismissBanner(banner)
        }
    }

    private func dismissBanner(_ banner: BannerKind) {
        switch banner {
        case .error(let msg):
            if state.model.errorMessage == msg { state.model.errorMessage = nil }
        case .success(let msg):
            if state.model.successMessage == msg { state.model.successMessage = nil }
        }
    }

    // MARK: - Alert Bindings

    private var discardAlertBinding: Binding<Bool> {
        Binding(
            get: { state.discardTarget != nil },
            set: { if !$0 { state.discardTarget = nil } }
        )
    }

    private var stashAlertBinding: Binding<Bool> {
        Binding(
            get: { state.pendingBranchSwitch != nil },
            set: { if !$0 { state.pendingBranchSwitch = nil } }
        )
    }

    private var discardAlertMessage: String {
        switch state.discardTarget {
        case .files(let files, _) where files.count == 1:
            "This will discard changes to \"\(files[0].repositoryRelativePath)\". This cannot be undone."
        case .files(let files, _):
            "This will discard changes to \(files.count) files. This cannot be undone."
        case .all:
            "This will discard all unstaged changes. This cannot be undone."
        case .none:
            ""
        }
    }
}
