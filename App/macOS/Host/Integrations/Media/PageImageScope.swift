import Foundation

/// A page may load images from its task folder, folders it explicitly names,
/// and individual image paths it shows. Filenames may be assembled at runtime;
/// recording the page never enumerates folders or reads the images themselves.
nonisolated struct PageImageScope {
    private let folders: Set<String>
    private let files: Set<String>

    init(html: String, directory: String, imagePaths: [String]) {
        var folders = Set([Self.canonicalPath(directory)])
        var files = Set(imagePaths.map(Self.canonicalPath))
        let home = Self.canonicalPath(FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false))
        for match in html.matches(of: Self.pathLiteral) {
            let source = String(match.output.2)
            guard !source.contains("${"), let components = URLComponents(string: source) else { continue }
            let path = Self.canonicalPath(TranscriptMedia.resolve(components.path, in: directory))
            guard components.path.hasSuffix("/") else {
                files.insert(path)
                continue
            }
            // A page naming a folder doesn't grant the whole filesystem or home.
            guard path != "/", path != home, !home.hasPrefix(path + "/") else { continue }
            folders.insert(path)
        }
        self.folders = folders
        self.files = files
    }

    /// `path` must already be canonical, and that same path must be opened.
    /// The slash boundary rejects siblings; resolving symlinks rejects escapes.
    func allows(canonicalPath path: String) -> Bool {
        files.contains(path) || folders.contains { path.hasPrefix($0 + "/") }
    }

    static func canonicalPath(_ path: String) -> String {
        URL(filePath: path, directoryHint: .notDirectory).standardizedFileURL
            .resolvingSymlinksInPath().path(percentEncoded: false)
    }

    // Complete local paths in HTML, CSS, or JS strings. A trailing slash names
    // a folder; a complete filename grants only that file. Matching delimiters
    // and rejecting interpolation keeps expressions from becoming scopes.
    nonisolated(unsafe) private static let pathLiteral = #/(["'`])((?:/(?!/)|~/)[^"'`<>\n\r\\]*)\1/#
}
