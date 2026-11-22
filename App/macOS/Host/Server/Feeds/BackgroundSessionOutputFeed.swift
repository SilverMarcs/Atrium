import AtriumProtocol
import Foundation
import Observation

/// Live output of one agent-run background shell session: tails a log file on
/// disk for file-backed providers (Claude, Antigravity), or reads buffered
/// adapter output for RPC-backed providers (Codex).
@MainActor
final class BackgroundSessionOutputFeed: TopicFeed {
    let workspaceID: UUID
    let sessionID: String
    private let integrations: AgentIntegrationStore
    private(set) var current: HostEvent?
    private var attachTask: Task<Void, Never>?
    private var streamTask: Task<Void, Never>?

    /// Cap the initial tail read so opening a huge existing build log stays cheap.
    private nonisolated static let initialReadCapBytes = 256 * 1024

    init(workspaceID: UUID, sessionID: String, integrations: AgentIntegrationStore) {
        self.workspaceID = workspaceID
        self.sessionID = sessionID
        self.integrations = integrations
    }

    func start(publish: @escaping (HostEvent) -> Void) {
        stop()
        attachTask = Task { @MainActor [weak self] in
            let lookup = Observations { [weak self] () -> AgentBackgroundSession? in
                guard let self else { return nil }
                return self.integrations.backgroundSessions.first { $0.id == self.sessionID }
            }
            for await session in lookup {
                guard let self, !Task.isCancelled else { return }
                guard let session else { continue }
                if let path = session.outputFilePath {
                    self.startFileTail(path: path, publish: publish)
                } else {
                    self.startAdapterObservation(session: session, publish: publish)
                }
                return
            }
        }
    }

    func stop() {
        attachTask?.cancel()
        attachTask = nil
        streamTask?.cancel()
        streamTask = nil
    }

    private func startFileTail(path: String, publish: @escaping (HostEvent) -> Void) {
        let url = URL(filePath: path)
        streamTask = Task { @MainActor [weak self] in
            var buffer = CommandOutput()
            var offset: UInt64 = 0
            var didReadInitial = false

            @MainActor
            func emit() {
                guard let self else { return }
                let event = HostEvent.backgroundSessionOutput(workspaceID: self.workspaceID, sessionID: self.sessionID, output: buffer.wire)
                self.current = event
                publish(event)
            }

            @MainActor
            func pull() async {
                let startOffset = offset
                let isInitial = !didReadInitial
                let chunk = await Task.detached { () -> (data: Data, newOffset: UInt64, reset: Bool)? in
                    guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                          let sizeNum = attrs[.size] as? NSNumber else { return nil }
                    let size = sizeNum.uint64Value
                    var readFrom = startOffset
                    var reset = false
                    if isInitial, size > UInt64(Self.initialReadCapBytes) {
                        readFrom = size - UInt64(Self.initialReadCapBytes)
                    } else if size < startOffset {
                        readFrom = 0
                        reset = true
                    }
                    guard size > readFrom || reset else { return nil }
                    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
                    defer { try? handle.close() }
                    try? handle.seek(toOffset: readFrom)
                    let data = (try? handle.readToEnd()) ?? Data()
                    return (data, readFrom + UInt64(data.count), reset)
                }.value
                if let chunk {
                    if chunk.reset { buffer.clear() }
                    if !didReadInitial, offset == 0, chunk.newOffset > UInt64(chunk.data.count) {
                        // Drop a leading partial line when starting mid-file.
                        if let newline = chunk.data.firstIndex(of: 10) {
                            buffer.append(Data(chunk.data[(newline + 1)...]))
                        } else {
                            buffer.append(chunk.data)
                        }
                    } else {
                        buffer.append(chunk.data)
                    }
                    offset = chunk.newOffset
                    didReadInitial = true
                    emit()
                } else if !didReadInitial {
                    didReadInitial = true
                    emit()
                }
            }

            // The log is appended to by another process, so read what's new twice a second.
            while !Task.isCancelled, self != nil {
                await pull()
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private func startAdapterObservation(session: AgentBackgroundSession, publish: @escaping (HostEvent) -> Void) {
        let empty = WireCommandOutput(id: UUID(), firstLine: 0, start: 0, lines: [])
        streamTask = Task { @MainActor [weak self] in
            let revisions = Observations { [weak self] in
                guard let self else { return -1 }
                return self.integrations.backgroundOutputRevisions[self.sessionID, default: 0]
            }
            for await revision in revisions {
                guard let self, revision >= 0, !Task.isCancelled else { return }
                let output = await self.integrations.backgroundSessionOutput(for: session)
                    ?? empty
                let event = HostEvent.backgroundSessionOutput(workspaceID: self.workspaceID, sessionID: self.sessionID, output: output)
                self.current = event
                publish(event)
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }
}
