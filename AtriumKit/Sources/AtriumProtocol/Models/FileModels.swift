import Foundation

/// One item in a folder on a host.
public nonisolated struct FileEntry: Codable, Sendable, Hashable, Identifiable {
    public var name: String
    public var path: String
    public var isDirectory: Bool

    public init(name: String, path: String, isDirectory: Bool) {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
    }

    public var id: String { path }
    public var isHidden: Bool { name.hasPrefix(".") }
    public var url: URL { URL(filePath: path, directoryHint: isDirectory ? .isDirectory : .notDirectory) }

    /// Folders first, then by name as Finder sorts it.
    public static func precedes(_ lhs: FileEntry, _ rhs: FileEntry) -> Bool {
        if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }

    /// Folders that are never worth showing or searching.
    public static let ignoredNames: Set<String> = [
        ".DS_Store", ".git", "node_modules", ".build", "DerivedData",
        "Pods", "__pycache__", ".venv", "venv", ".svn", ".hg", "target",
    ]
}

/// What a client can show of a file, capped so previews stay cheap.
public nonisolated enum FilePreview: Codable, Sendable, Equatable {
    case text(String)
    case image(Data)
    case tooLarge(bytes: Int64)
    case binary
}

/// A file with lines that contain a search query.
public nonisolated struct FileSearchResult: Codable, Sendable, Equatable, Identifiable {
    public var path: String
    /// Relative to the folder searched.
    public var relativePath: String
    public var matches: [FileSearchMatch]

    public init(path: String, relativePath: String, matches: [FileSearchMatch]) {
        self.path = path
        self.relativePath = relativePath
        self.matches = matches
    }

    public var id: String { relativePath }
    public var name: String { URL(filePath: relativePath).lastPathComponent }
}

public nonisolated struct FileSearchMatch: Codable, Sendable, Equatable, Identifiable {
    public var lineNumber: Int
    /// The line, trimmed to its first 500 characters.
    public var line: String
    /// Character offsets of the match within `line`.
    public var columns: Range<Int>

    public init(lineNumber: Int, line: String, columns: Range<Int>) {
        self.lineNumber = lineNumber
        self.line = line
        self.columns = columns
    }

    public var id: String { "\(lineNumber):\(columns.lowerBound)" }
}

public nonisolated enum FileTypes {
    public static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tiff", "tif", "bmp", "ico", "icns", "svg",
    ]

    public static let binaryExtensions: Set<String> = [
        "mp4", "mov", "avi", "mkv", "webm", "m4v", "mp3", "wav", "flac", "m4a", "aac", "ogg",
        "zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar", "dmg", "iso",
        "sqlite", "sqlite3", "db", "pdf", "exe", "dylib", "so", "o", "a",
        "xlsx", "xls", "docx", "doc", "pptx", "ppt", "pages", "numbers", "key", "keynote",
        "parquet", "arrow", "feather", "npy", "npz", "pkl", "h5", "hdf5",
        "ttf", "otf", "woff", "woff2",
    ]

    public static func isImage(_ path: String) -> Bool {
        imageExtensions.contains(URL(filePath: path).pathExtension.lowercased())
    }

    public static func isKnownBinary(_ path: String) -> Bool {
        binaryExtensions.contains(URL(filePath: path).pathExtension.lowercased())
    }
}
