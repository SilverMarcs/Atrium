import Foundation

/// A draft put aside in a project's scratchpad. Its images are files beside
/// the projects' data, so the projects file stays small.
nonisolated struct ScratchpadEntry: Codable, Identifiable {
    var id = UUID()
    var text: String
    /// Names of the JPEG files in `directory`.
    var imageFiles: [String] = []

    static let directory = HostStorage.directory.appending(path: "TaskWorkspace/Scratchpad", directoryHint: .isDirectory)

    /// Saves a draft's images as files.
    /// - Returns: The files' names.
    static func save(_ images: [Data]) throws -> [String] {
        guard !images.isEmpty else { return [] }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try images.map { data in
            let name = "\(UUID().uuidString).jpg"
            try data.write(to: directory.appending(path: name))
            return name
        }
    }

    var imageURLs: [URL] { imageFiles.map { Self.directory.appending(path: $0) } }

    /// The images as they were added.
    func images() -> [Data] {
        imageURLs.compactMap { try? Data(contentsOf: $0) }
    }

    func deleteImages() {
        for url in imageURLs { try? FileManager.default.removeItem(at: url) }
    }
}
