import AppKit
import Foundation

enum FileEditorUnsupportedReason: Sendable {
    case tooLarge(bytes: Int64)
    case binary
}

enum FileEditorLoadOutcome: Sendable {
    case text(String, modificationDate: Date?)
    case image(NSImage)
    case unsupported(FileEditorUnsupportedReason)
    case error(String)
}

@Observable
@MainActor
final class FileEditorLoadModel {
    enum Phase {
        case idle
        case loading
        case text
        case image(NSImage)
        case unsupported(FileEditorUnsupportedReason)
        case error(String)
    }

    private(set) var phase: Phase = .idle
    var content: String = ""
    private(set) var savedContent: String = ""
    private(set) var lastModificationDate: Date?
    private(set) var loadedURL: URL?

    private var loadTask: Task<Void, Never>?

    func load(fileURL: URL) {
        loadTask?.cancel()
        phase = .loading
        content = ""
        savedContent = ""
        lastModificationDate = nil
        loadedURL = nil

        loadTask = Task.detached(priority: .userInitiated) { [weak self] in
            let outcome = FileLoadEngine.performLoad(fileURL: fileURL)
            guard !Task.isCancelled else { return }
            await self?.apply(outcome, fileURL: fileURL)
        }
    }

    func reloadIfChanged(fileURL: URL) {
        guard case .text = phase, content == savedContent else { return }
        let previousModDate = lastModificationDate
        loadTask?.cancel()
        loadTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let outcome = FileLoadEngine.performReload(fileURL: fileURL, previousModDate: previousModDate) else { return }
            guard !Task.isCancelled else { return }
            await self?.apply(outcome, fileURL: fileURL)
        }
    }

    func markSaved() {
        savedContent = content
    }

    private func apply(_ outcome: FileEditorLoadOutcome, fileURL: URL) {
        loadedURL = fileURL
        switch outcome {
        case .text(let string, let modDate):
            content = string
            savedContent = string
            lastModificationDate = modDate
            phase = .text
        case .image(let image):
            phase = .image(image)
        case .unsupported(let reason):
            phase = .unsupported(reason)
        case .error(let message):
            phase = .error(message)
        }
    }
}

private let maxEditableBytes: Int64 = 256 * 1024

enum FileLoadEngine {
    nonisolated static func performLoad(fileURL: URL) -> FileEditorLoadOutcome {
        if fileURL.isPreviewableImage {
            if let image = NSImage(contentsOf: fileURL) {
                return .image(image)
            }
            return .unsupported(.binary)
        }

        if fileURL.isKnownBinary {
            return .unsupported(.binary)
        }

        let fileSize: Int64
        do {
            let values = try fileURL.resourceValues(forKeys: [.fileSizeKey])
            fileSize = Int64(values.fileSize ?? 0)
        } catch {
            return .error(error.localizedDescription)
        }
        if fileSize > maxEditableBytes {
            return .unsupported(.tooLarge(bytes: fileSize))
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let sniffCount = min(data.count, 8192)
            if data.prefix(sniffCount).contains(0) {
                return .unsupported(.binary)
            }
            guard let string = String(data: data, encoding: .utf8) else {
                return .unsupported(.binary)
            }
            let modDate = (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.modificationDate] as? Date
            return .text(string, modificationDate: modDate)
        } catch {
            return .error(error.localizedDescription)
        }
    }

    nonisolated static func performReload(fileURL: URL, previousModDate: Date?) -> FileEditorLoadOutcome? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let modDate = attrs[.modificationDate] as? Date,
              modDate != previousModDate else { return nil }
        guard let data = try? Data(contentsOf: fileURL),
              let string = String(data: data, encoding: .utf8) else { return nil }
        return .text(string, modificationDate: modDate)
    }
}
