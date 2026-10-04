import Foundation
import Network
import Observation

@MainActor
final class GitSubscription {
    private weak var workspace: Workspace?
    private let notify: () -> Void
    private var debounceTask: Task<Void, Never>?
    private var invalidated = false

    init(workspace: Workspace, notify: @escaping () -> Void) {
        self.workspace = workspace
        self.notify = notify
    }

    func start() {
        arm()
    }

    func invalidate() {
        invalidated = true
        debounceTask?.cancel()
        debounceTask = nil
    }

    private func arm() {
        guard !invalidated, let workspace else { return }
        withObservationTracking { [weak self] in
            guard let workspace = self?.workspace else { return }
            _ = workspace.inspectorState.git.model.snapshots
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.invalidated else { return }
                self.debounceTask?.cancel()
                self.debounceTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(150))
                    if Task.isCancelled { return }
                    guard let self, !self.invalidated else { return }
                    self.notify()
                    self.arm()
                }
            }
        }
    }
}
