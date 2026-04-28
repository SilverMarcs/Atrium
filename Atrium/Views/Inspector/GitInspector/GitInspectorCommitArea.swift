import SwiftUI

struct GitInspectorCommitArea: View {
    let directoryURL: URL
    @Bindable var state: GitInspectorState

    private var snapshot: GitRepositoryStatusSnapshot? { state.currentSnapshot }

    private var currentAction: SourceControlAction {
        guard let snapshot else { return .commit }
        if !snapshot.stagedFiles.isEmpty { return .commit }
        if !snapshot.unpushedCommits.isEmpty { return .push }
        if !snapshot.hasTrackingBranch { return .push }
        if snapshot.remoteAheadCount > 0 { return .pull }
        return .commit
    }

    private var needsUpstream: Bool {
        guard let snapshot else { return false }
        return !snapshot.hasTrackingBranch && currentAction == .push
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            TextField("Commit message", text: $state.commitMessage, axis: .vertical)
                .lineLimit(1...4)

            Button {
                perform()
            } label: {
                Image(systemName: currentAction.systemImage)
                    .contentTransition(.symbolEffect(.replace))
            }
            .frame(width: 20)
            .offset(y: 1)
            .buttonStyle(.borderedProminent)
            .help(currentAction.label)
            .disabled(currentAction == .commit && (state.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || snapshot?.stagedFiles.isEmpty != false))
        }
    }

    private func perform() {
        guard let snapshot else { return }
        switch currentAction {
        case .commit:
            let message = state.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !message.isEmpty, !snapshot.stagedFiles.isEmpty else { return }
            Task {
                await state.model.commit(message: message, snapshot: snapshot)
                state.commitMessage = ""
                await state.refresh(directoryURL: directoryURL)
            }
        case .push:
            if needsUpstream {
                state.showPushUpstreamAlert = true
                return
            }
            if snapshot.remoteAheadCount > 0 {
                state.showPullRebaseAlert = true
                return
            }
            state.perform(.push(snapshot), directoryURL: directoryURL)
        case .pull:
            if !snapshot.unpushedCommits.isEmpty {
                state.showPullRebaseAlert = true
                return
            }
            Task {
                await state.model.pull(snapshot: snapshot)
                await state.refresh(directoryURL: directoryURL)
            }
        }
    }
}

enum SourceControlAction {
    case commit
    case push
    case pull

    var label: String {
        switch self {
        case .commit: "Commit"
        case .push: "Push"
        case .pull: "Pull"
        }
    }

    var systemImage: String {
        switch self {
        case .commit: "checkmark.circle"
        case .push: "arrow.up"
        case .pull: "arrow.down"
        }
    }
}
