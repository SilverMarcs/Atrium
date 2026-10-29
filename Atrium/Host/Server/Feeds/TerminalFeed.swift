import AtriumProtocol
import Foundation
import SwiftTerm

/// Samples only while followed. The process and parsed terminal remain owned
/// by TaskSessionController when every viewer leaves.
@MainActor
final class TerminalFeed: TopicFeed {
    private let session: TaskSession
    private let sessions: TaskSessionController
    private var observation: Task<Void, Never>?
    private var publish: ((HostEvent) -> Void)?
    private var lastOutput: UInt64?
    private var lastDimensions: TerminalDimensions?
    private var lastTerminalID: UUID?
    private var lastExited: Bool?
    private var sequence: UInt64 = 0
    private var needsAttachment = true
    private var screenCapture = TerminalScreenCapture()
    private(set) var current: HostEvent?

    init(session: TaskSession, sessions: TaskSessionController) {
        self.session = session
        self.sessions = sessions
    }

    func start(publish: @escaping (HostEvent) -> Void) {
        self.publish = publish
        observation = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                if needsAttachment {
                    needsAttachment = false
                    // Following an exited screen must not restart its process.
                    if !session.isTerminalAttached, !session.terminal.hasExited {
                        await sessions.attachTerminal(to: session)
                    }
                }
                guard !Task.isCancelled else { return }
                if !session.isAttachingTerminal { capture() }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    func refresh() {
        lastOutput = nil
        if session.terminalError != nil { needsAttachment = true }
    }

    func stop() {
        observation?.cancel()
        observation = nil
        publish = nil
    }

    private func unavailable(_ message: String) {
        let event = HostEvent.terminalUnavailable(taskID: session.id, message: message)
        if case .terminalUnavailable(_, let previous) = current, previous == message { return }
        current = event
        publish?(event)
    }

    private func capture() {
        guard sessions.sessions[session.id] === session else {
            unavailable("This task’s terminal is no longer available.")
            return
        }
        if let error = session.terminalError { unavailable(error); return }
        guard let view = session.terminal.localProcessTerminalView as? AppTerminalView else { return }
        let terminal = session.terminal
        let output = view.outputRevision
        let dimensions = view.terminalDimensions
        guard lastOutput != output || lastDimensions != dimensions || lastTerminalID != terminal.id || lastExited != terminal.hasExited else { return }
        sequence &+= 1
        guard let frame = screenCapture.frame(from: terminal, sequence: sequence) else {
            unavailable("This terminal is too large to display remotely.")
            return
        }
        lastOutput = output
        lastDimensions = dimensions
        lastTerminalID = terminal.id
        lastExited = terminal.hasExited
        let event = HostEvent.terminal(taskID: session.id, frame: frame)
        current = event
        publish?(event)
    }
}
