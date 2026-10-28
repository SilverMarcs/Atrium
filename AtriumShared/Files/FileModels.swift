import Foundation

/// One item in a folder on a host.
nonisolated struct FileEntry: Codable, Sendable, Hashable, Identifiable {
    var name: String
    var path: String
    var isDirectory: Bool

    var id: String { path }
    var isHidden: Bool { name.hasPrefix(".") }
    var url: URL { URL(filePath: path, directoryHint: isDirectory ? .isDirectory : .notDirectory) }

    /// Folders first, then by name as Finder sorts it.
    static func precedes(_ lhs: FileEntry, _ rhs: FileEntry) -> Bool {
        if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }

    /// Folders that are never worth showing or searching.
    static let ignoredNames: Set<String> = [
        ".DS_Store", ".git", "node_modules", ".build", "DerivedData",
        "Pods", "__pycache__", ".venv", "venv", ".svn", ".hg", "target",
    ]
}

/// What a client can show of a file, capped so previews stay cheap.
nonisolated enum FilePreview: Codable, Sendable, Equatable {
    case text(String)
    case image(Data)
    case tooLarge(bytes: Int64)
    case binary
}

/// A file with lines that contain a search query.
nonisolated struct FileSearchResult: Codable, Sendable, Equatable, Identifiable {
    var path: String
    /// Relative to the folder searched.
    var relativePath: String
    var matches: [FileSearchMatch]

    var id: String { relativePath }
    var name: String { (relativePath as NSString).lastPathComponent }
}

nonisolated struct FileSearchMatch: Codable, Sendable, Equatable, Identifiable {
    var lineNumber: Int
    /// The line, trimmed to its first 500 characters.
    var line: String
    /// Character offsets of the match within `line`.
    var columns: Range<Int>

    var id: String { "\(lineNumber):\(columns.lowerBound)" }
}

nonisolated enum FileTypes {
    static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tiff", "tif", "bmp", "ico", "icns", "svg",
    ]

    static let binaryExtensions: Set<String> = [
        "mp4", "mov", "avi", "mkv", "webm", "m4v", "mp3", "wav", "flac", "m4a", "aac", "ogg",
        "zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar", "dmg", "iso",
        "sqlite", "sqlite3", "db", "pdf", "exe", "dylib", "so", "o", "a",
        "xlsx", "xls", "docx", "doc", "pptx", "ppt", "pages", "numbers", "key", "keynote",
        "parquet", "arrow", "feather", "npy", "npz", "pkl", "h5", "hdf5",
        "ttf", "otf", "woff", "woff2",
    ]

    static func isImage(_ path: String) -> Bool {
        imageExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    static func isKnownBinary(_ path: String) -> Bool {
        binaryExtensions.contains((path as NSString).pathExtension.lowercased())
    }
}
