import Foundation
import SwiftTerm

/// Tracks which job owns a shell's PTY, driven by process events rather than
/// polling. A job starts when a shell child execs (it takes the PTY before
/// exec) and ends when that child exits; the shell redraws its prompt after
/// reclaiming the PTY, so `refresh()` on output settles any exit race. No shell
/// hooks are injected.
@MainActor
final class ForegroundJobMonitor {
    /// Process group of the foreground job, or nil while the shell is at its prompt.
    private(set) var job: pid_t?

    private let process: LocalProcess
    private let onChange: (pid_t?) -> Void
    private var forkSource: (any DispatchSourceProcess)?
    private var childSources: [pid_t: any DispatchSourceProcess] = [:]

    init(process: LocalProcess, onChange: @escaping (pid_t?) -> Void) {
        self.process = process
        self.onChange = onChange

        let source = DispatchSource.makeProcessSource(identifier: process.shellPid, eventMask: .fork, queue: .main)
        source.setEventHandler { [weak self] in
            self?.watchNewChildren()
        }
        source.resume()
        forkSource = source
        refresh()
    }

    /// Re-reads the PTY foreground and reports a change.
    func refresh() {
        let current = foregroundGroup()
        guard current != job else { return }
        job = current
        onChange(current)
    }

    func cancel() {
        forkSource?.cancel()
        forkSource = nil
        for source in childSources.values {
            source.cancel()
        }
        childSources.removeAll()
    }

    private func foregroundGroup() -> pid_t? {
        guard process.running else { return nil }
        let group = tcgetpgrp(process.childfd)
        // An exited job stays the PTY foreground until the shell reclaims it.
        guard group > 0, group != process.shellPid, ProcessTable.groupIsAlive(group) else { return nil }
        return group
    }

    private func watchNewChildren() {
        for pid in ProcessTable.children(of: process.shellPid) where childSources[pid] == nil {
            // A child that already exited reports exit as soon as this resumes.
            let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: [.exec, .exit], queue: .main)
            source.setEventHandler { [weak self, weak source] in
                guard let self, let source else { return }
                if source.data.contains(.exit) {
                    source.cancel()
                    self.childSources[pid] = nil
                }
                self.refresh()
            }
            source.resume()
            childSources[pid] = source
        }
        // A child may have taken the PTY before its watcher was registered.
        refresh()
    }
}
