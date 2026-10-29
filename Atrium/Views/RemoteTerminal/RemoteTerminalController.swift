import AtriumClient
import AtriumProtocol
import Foundation
import Observation

@MainActor
@Observable
final class RemoteTerminalController {
    let host: HostClient
    let taskID: String
    private(set) var isResuming = false
    @ObservationIgnored private var pendingInput: [(terminalID: UUID, data: Data)] = []
    @ObservationIgnored private var inputTask: Task<Void, Never>?
    @ObservationIgnored private var inputGeneration = UUID()

    init(host: HostClient, taskID: String) {
        self.host = host
        self.taskID = taskID
    }

    func follow() async {
        defer { discardInput() }
        async let subscription: Void = host.follow(.terminal(taskID: taskID))
        for await change in host.changes() {
            if case .state = change { discardInput() }
            if case .event(.terminal(let id, let frame)) = change, id == taskID,
               let pending = pendingInput.first, pending.terminalID != frame.terminalID { discardInput() }
        }
        await subscription
    }

    /// Await every write before the next, including paste chunks. Typed input
    /// is never retried after a disconnect or delivered to a restarted process.
    func send(_ data: Data) {
        guard host.isConnected, host.terminalErrors[taskID] == nil,
              let frame = host.terminals[taskID], !frame.hasExited, !data.isEmpty else { return }
        guard data.count + pendingInput.reduce(0, { $0 + $1.data.count }) <= 1024 * 1024 else {
            host.actionError = "The terminal input is too large. Paste a smaller selection."
            return
        }
        for offset in stride(from: 0, to: data.count, by: 16_384) {
            pendingInput.append((frame.terminalID, data.subdata(in: offset..<min(offset + 16_384, data.count))))
        }
        guard inputTask == nil else { return }
        let generation = inputGeneration
        inputTask = Task { [weak self] in
            guard let self else { return }
            defer { if inputGeneration == generation { inputTask = nil } }
            do {
                while !pendingInput.isEmpty, !Task.isCancelled, inputGeneration == generation {
                    let input = pendingInput.removeFirst()
                    guard host.terminals[taskID]?.terminalID == input.terminalID else { pendingInput.removeAll(); return }
                    _ = try await host.request(.terminal(taskID: taskID, action: .input(terminalID: input.terminalID, data: input.data)))
                }
            } catch {
                if inputGeneration == generation { pendingInput.removeAll() }
                if host.isConnected, !Task.isCancelled { host.actionError = error.localizedDescription }
            }
        }
    }

    func resume() async {
        guard !isResuming else { return }
        isResuming = true
        defer { isResuming = false }
        _ = await host.perform(.terminal(taskID: taskID, action: .resume))
    }

    private func discardInput() {
        inputTask?.cancel()
        inputTask = nil
        inputGeneration = UUID()
        pendingInput.removeAll()
    }
}
