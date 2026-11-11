import AtriumProtocol
import SwiftUI

struct GitInspectorCommitArea: View {
    @Bindable var state: GitInspectorState

    private var snapshot: GitRepositoryStatus? { state.currentSnapshot }

    private var currentAction: SourceControlAction {
        guard let snapshot else { return .commit }
        if !snapshot.stagedFiles.isEmpty { return .commit }
        if !snapshot.unpushedCommits.isEmpty { return .push }
        if !snapshot.hasTrackingBranch { return .push }
        if snapshot.remoteAheadCount > 0 { return .pull }
        return .commit
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
            let message = state.commitMessage
            Task {
                await state.model.commit(message: message, in: snapshot)
                state.commitMessage = ""
            }
        case .push:
            Task { await state.model.push(snapshot) }
        case .pull:
            Task { await state.model.pull(snapshot) }
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
