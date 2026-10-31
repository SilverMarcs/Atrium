import AtriumProtocol
import Foundation

/// Serves the pages and images agents show in a task's chat. Pages come from
/// memory and images from disk, as they are now; nothing is copied.
///
/// A client may fetch only what the task's transcript shows. What isn't known
/// yet, as after Atrium restarts while a client still shows the chat, is looked
/// for again after reading the transcript once more.
@MainActor
final class MediaService {
    private let integrations: AgentIntegrationStore
    /// Transcripts being read again, so requests for a chat's media share one read.
    private var rereads: [String: Task<Void, Never>] = [:]

    init(integrations: AgentIntegrationStore) {
        self.integrations = integrations
    }

    func page(_ key: String, inTask taskID: String) async -> HostReply {
        guard let thread = integrations.threads.first(where: { $0.id == taskID }) else {
            return .failed(message: "This task no longer exists.")
        }
        let media = integrations.media
        let cached = { media.shows(page: key, in: taskID) ? ChatPages.html(forKey: key) : nil }
        if cached() == nil { await reread(thread) }
        guard let html = cached() else { return .failed(message: "That page is no longer available.") }
        return .page(html: html)
    }

    func image(_ path: String, maxPixelSize: Int, inTask taskID: String) async -> HostReply {
        guard let thread = integrations.threads.first(where: { $0.id == taskID }) else {
            return .failed(message: "This task no longer exists.")
        }
        let file = TranscriptMedia.resolve(path, in: thread.directory)
        if !integrations.media.shows(image: file, in: taskID) { await reread(thread) }
        guard integrations.media.shows(image: file, in: taskID) else {
            return .failed(message: "That image isn’t part of this chat.")
        }
        guard let data = await TranscriptImage.display(at: URL(filePath: file), maxPixelSize: maxPixelSize) else {
            return .failed(message: "That image is no longer available.")
        }
        return .image(data: data)
    }

    /// Reads the task's transcript again, which records what it shows.
    private func reread(_ thread: AgentThread) async {
        let task = rereads[thread.id] ?? Task { [integrations] in
            _ = try? await integrations.transcript(for: thread)
        }
        rereads[thread.id] = task
        await task.value
        if rereads[thread.id] == task { rereads[thread.id] = nil }
    }
}
