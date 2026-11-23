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

    private var isActionDisabled: Bool {
        currentAction == .commit
            && (state.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || snapshot?.stagedFiles.isEmpty != false)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            GitInspectorMoreMenu(state: state)

            TextField("Commit message", text: $state.commitMessage, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.subheadline)
                .lineLimit(1...4)
                // Aligns the 14pt first line with the 15pt icons under top alignment.
                .padding(.top, 0.5)

            Button {
                perform()
            } label: {
                Image(systemName: currentAction.systemImage(filled: !isActionDisabled))
                    .foregroundStyle(isActionDisabled ? .secondary : Color.accentColor)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .help(currentAction.label)
            .disabled(isActionDisabled)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        // Half of SearchBar's 25pt single-line height, so one line matches its
        // Capsule while 2–4 lines keep a bounded corner radius.
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12.5))
    }

    private func perform() {
        guard let snapshot else { return }
        switch currentAction {
        case .commit:
            let message = state.commitMessage
            Task {
                // Keep the message when the commit fails, or when it was edited meanwhile.
                guard await state.model.commit(message: message, in: snapshot),
                      state.commitMessage == message else { return }
                state.commitMessage = ""
            }
        case .push:
            Task { await state.model.push(snapshot) }
        case .pull:
            Task { await state.model.pull(snapshot) }
        }
    }
}

private enum SourceControlAction {
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

    func systemImage(filled: Bool) -> String {
        let base = switch self {
        case .commit: "checkmark.circle"
        case .push: "arrow.up.circle"
        case .pull: "arrow.down.circle"
        }
        return filled ? "\(base).fill" : base
    }
}
