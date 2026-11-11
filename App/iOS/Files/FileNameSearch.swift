import AtriumClient
import AtriumProtocol
import Foundation
import Observation

/// Uses the host's bounded filename lookup, sharing the Mac browser's transport.
@MainActor
@Observable
final class FileNameSearch {
    var text = "" {
        didSet {
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { clear() }
        }
    }
    private(set) var submittedText = ""
    private(set) var paths: [String]?
    private(set) var isTruncated = false
    private(set) var error: String?
    @ObservationIgnored private var task: Task<Void, Never>?

    var isActive: Bool { !submittedText.isEmpty }

    func submit(in folder: String, host: HostClient, workspaceID: UUID) {
        clear()
        submittedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !submittedText.isEmpty else { return }
        let query = submittedText
        task = Task {
            do {
                try Task.checkCancellation()
                guard case .found(let paths, let isTruncated) = try await host.files(
                    .find(root: folder, query: query), in: workspaceID
                ) else { throw HostClientError.unexpectedReply }
                try Task.checkCancellation()
                self.paths = paths
                self.isTruncated = isTruncated
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
        }
    }

    private func clear() {
        task?.cancel()
        task = nil
        submittedText = ""
        paths = nil
        isTruncated = false
        error = nil
    }
}
