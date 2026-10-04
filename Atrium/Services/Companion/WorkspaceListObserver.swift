import Foundation
import Network
import Observation

@MainActor
final class WorkspaceListObserver {
    private weak var store: WorkspaceStore?
    private let notify: () -> Void
    private var debounceTask: Task<Void, Never>?
    private var invalidated = false

    init(store: WorkspaceStore, notify: @escaping () -> Void) {
        self.store = store
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
        guard !invalidated, let store else { return }
        withObservationTracking { [weak self] in
            guard let store = self?.store else { return }
            for ws in store.workspaces {
                _ = ws.name
                _ = ws.isArchived
                _ = ws.customIconFilename
                _ = ws.scratchPad
                for chat in ws.chats {
                    _ = chat.title
                    _ = chat.turnCount
                    _ = chat.date
                    _ = chat.isArchived
                    _ = chat.hasNotification
                    _ = chat.session.isConnected
                    _ = chat.session.isProcessing
                }
            }
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
