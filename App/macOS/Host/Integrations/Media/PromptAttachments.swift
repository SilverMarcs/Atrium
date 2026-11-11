import Foundation

/// Images attached to prompts from clients, written to files the agent can
/// read. They live in the temporary directory and are pruned after a week.
nonisolated enum PromptAttachments {
    private static let directory = URL.temporaryDirectory.appending(path: "PromptAttachments", directoryHint: .isDirectory)
    private static let maxAge: TimeInterval = 7 * 24 * 60 * 60
    private static let maxCount = 10

    static func reference(to url: URL) -> String {
        "@\"" + url.path.replacing("\\", with: "\\\\").replacing("\"", with: "\\\"") + "\""
    }

    /// Only the leading references Atrium adds, never paths in the user's prose
    /// or references to files elsewhere in their project. Recognition does not
    /// depend on the file still existing.
    static func references(in text: String) -> (text: String, files: [URL]) {
        var remainder = text[...]
        var files: [URL] = []
        while let line = remainder.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first,
              line.hasPrefix("@\""), line.hasSuffix("\"") {
            let path = String(line.dropFirst(2).dropLast()).replacing("\\\"", with: "\"").replacing("\\\\", with: "\\")
            let url = URL(fileURLWithPath: path)
            guard path.hasPrefix("/"), url.pathExtension == "jpg",
                  UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil,
                  url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
                    == directory.standardizedFileURL.resolvingSymlinksInPath() else { break }
            files.append(url)
            remainder = remainder.dropFirst(line.count)
            if remainder.first == "\n" { remainder = remainder.dropFirst() }
        }
        return (String(remainder), files)
    }

    /// Saves JPEG images and returns their files, in order.
    static func save(_ images: [Data]) throws -> [URL] {
        guard !images.isEmpty else { return [] }
        guard images.count <= maxCount else {
            throw IntegrationError(message: "Attach up to \(maxCount) images at a time.")
        }
        guard images.allSatisfy({ $0.starts(with: [0xFF, 0xD8, 0xFF]) }) else {
            throw IntegrationError(message: "Only JPEG images can be attached.")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        pruneOldFiles()
        return try images.map { data in
            let url = directory.appending(path: "\(UUID().uuidString).jpg")
            try data.write(to: url, options: .atomic)
            return url
        }
    }

    private static func pruneOldFiles() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        for file in files {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, Date.now.timeIntervalSince(modified) > maxAge {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
}
