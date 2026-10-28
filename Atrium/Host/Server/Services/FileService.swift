import AppKit
import Foundation

/// Serves a project's files to clients: folder listings one level at a time,
/// capped previews and searches, and, for the host itself, edits.
enum FileService {
    static func handle(_ request: FileRequest, in workspace: Workspace, isLocal: Bool) async -> HostReply {
        let access = WorkspaceAccess(directory: workspace.directory)
        guard request.paths.allSatisfy(access.allows) else {
            return .failed(message: "That file isn’t part of this project.")
        }
        if request.changesFiles, !isLocal { return .hostOnly }
        do {
            return .files(try await perform(request, in: workspace))
        } catch {
            return .failed(message: error.localizedDescription)
        }
    }

    private static func perform(_ request: FileRequest, in workspace: Workspace) async throws -> FileReply {
        switch request {
        case .list(let path):
            return .entries(await entries(in: path))
        case .find(let root, let query):
            let (paths, isTruncated) = await find(query, in: root)
            return .found(paths, isTruncated: isTruncated)
        case .search(let root, let query):
            let (results, isTruncated) = await search(query, in: root)
            return .matches(results, isTruncated: isTruncated)
        case .read(let path):
            return .preview(try await preview(of: path))
        case .resolveLink(let link, let directory):
            let roots = [workspace.directory] + (directory.map { [$0] } ?? [])
            guard let location = resolve(link, relativeTo: roots, access: WorkspaceAccess(directory: workspace.directory)) else {
                return .notFound
            }
            return .location(path: location.path, line: location.line)
        case .write(let path, let text):
            try text.write(toFile: path, atomically: true, encoding: .utf8)
            return .done
        case .create(let folder, let isFolder):
            let url = availableURL(named: isFolder ? "New Folder" : "Untitled", in: URL(filePath: folder))
            if isFolder {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            } else {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            return .path(url.path)
        case .rename(let path, let name):
            let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let source = URL(filePath: path)
            guard !name.isEmpty, !name.contains("/") else { return .path(path) }
            let destination = source.deletingLastPathComponent().appending(path: name)
            guard destination != source else { return .path(path) }
            try FileManager.default.moveItem(at: source, to: destination)
            return .path(destination.path)
        case .duplicate(let path):
            let source = URL(filePath: path)
            let name = source.deletingPathExtension().lastPathComponent
            let ext = source.pathExtension
            var suffix = 2
            var destination: URL
            repeat {
                destination = source.deletingLastPathComponent().appending(path: ext.isEmpty ? "\(name) \(suffix)" : "\(name) \(suffix).\(ext)")
                suffix += 1
            } while FileManager.default.fileExists(atPath: destination.path)
            try FileManager.default.copyItem(at: source, to: destination)
            return .path(destination.path)
        case .trash(let path):
            try FileManager.default.trashItem(at: URL(filePath: path), resultingItemURL: nil)
            return .done
        }
    }

    // MARK: - Reading

    /// A folder's entries, folders first, leaving out what's never worth showing.
    @concurrent
    static func entries(in path: String) async -> [FileEntry] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: URL(filePath: path, directoryHint: .isDirectory), includingPropertiesForKeys: Array(keys)
        )) ?? []
        return urls.compactMap { url in
            let name = url.lastPathComponent
            guard !FileEntry.ignoredNames.contains(name) else { return nil }
            let isDirectory = (try? url.resourceValues(forKeys: keys))?.isDirectory == true
            return FileEntry(name: name, path: url.filePath, isDirectory: isDirectory)
        }
        .sorted(by: FileEntry.precedes)
    }

    @concurrent
    private static func preview(of path: String) async throws -> FilePreview {
        let size = Int64((try FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0)
        if FileTypes.isImage(path) {
            guard size <= HostProtocol.maxPreviewImageBytes else { return .tooLarge(bytes: size) }
            return .image(try Data(contentsOf: URL(filePath: path)))
        }
        if FileTypes.isKnownBinary(path) { return .binary }
        guard size <= HostProtocol.maxPreviewTextBytes else { return .tooLarge(bytes: size) }
        let data = try Data(contentsOf: URL(filePath: path))
        guard !data.prefix(8192).contains(0), let text = String(data: data, encoding: .utf8) else { return .binary }
        return .text(text)
    }

    /// Files below `root` whose name contains `query`, as paths relative to it.
    @concurrent
    private static func find(_ query: String, in root: String) async -> ([String], Bool) {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return ([], false) }
        var found: [String] = []
        for relativePath in files(below: root, includingHidden: true) {
            guard !Task.isCancelled else { break }
            guard (relativePath as NSString).lastPathComponent.localizedStandardContains(query) else { continue }
            guard found.count < HostProtocol.maxFoundFiles else { return (found, true) }
            found.append(relativePath)
        }
        return (found, false)
    }

    /// Lines containing `query`, case-insensitively, in text files below `root`.
    @concurrent
    private static func search(_ query: String, in root: String) async -> ([FileSearchResult], Bool) {
        guard !query.isEmpty else { return ([], false) }
        var results: [FileSearchResult] = []
        var matchCount = 0
        let rootURL = URL(filePath: root, directoryHint: .isDirectory)
        for relativePath in files(below: root, includingHidden: false) {
            guard !Task.isCancelled else { break }
            guard results.count < HostProtocol.maxSearchFiles, matchCount < HostProtocol.maxSearchMatches else {
                return (results, true)
            }
            let url = rootURL.appending(path: relativePath)
            guard !FileTypes.isKnownBinary(relativePath),
                  let data = try? Data(contentsOf: url), !data.prefix(8192).contains(0),
                  let content = String(data: data, encoding: .utf8) else { continue }
            var matches: [FileSearchMatch] = []
            for (index, line) in content.components(separatedBy: .newlines).enumerated() {
                guard matchCount + matches.count < HostProtocol.maxSearchMatches else { break }
                let trimmed = String(line.prefix(500))
                guard let range = trimmed.range(of: query, options: .caseInsensitive) else { continue }
                let start = trimmed.distance(from: trimmed.startIndex, to: range.lowerBound)
                let end = trimmed.distance(from: trimmed.startIndex, to: range.upperBound)
                matches.append(FileSearchMatch(lineNumber: index + 1, line: trimmed, columns: start..<end))
            }
            guard !matches.isEmpty else { continue }
            results.append(FileSearchResult(path: url.filePath, relativePath: relativePath, matches: matches))
            matchCount += matches.count
        }
        return (results, false)
    }

    /// Relative paths of the regular files below `root`, skipping ignored folders.
    private nonisolated static func files(below root: String, includingHidden: Bool) -> [String] {
        let rootURL = URL(filePath: root, directoryHint: .isDirectory).standardizedFileURL
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: includingHidden ? [] : [.skipsHiddenFiles]
        ) else { return [] }
        let prefix = rootURL.filePath.count + (rootURL.filePath.hasSuffix("/") ? 0 : 1)
        var files: [String] = []
        for case let url as URL in enumerator {
            if FileEntry.ignoredNames.contains(url.lastPathComponent) {
                enumerator.skipDescendants()
                continue
            }
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            files.append(String(url.standardizedFileURL.filePath.dropFirst(prefix)))
        }
        return files
    }

    // MARK: - Links

    /// Resolves a clicked link to a file inside the project, or nil if it isn't
    /// one. Handles `file:` URLs, absolute, `~/`, and relative paths (against
    /// the given folders in order), plus a trailing `:line[:column]` suffix
    /// from compiler-style output.
    static func resolve(_ link: String, relativeTo roots: [String], access: WorkspaceAccess) -> (path: String, line: Int?)? {
        let rawPath: String
        if link.hasPrefix("file:") {
            guard let url = URL(string: link), url.isFileURL else { return nil }
            rawPath = url.filePath
        } else if link.contains("://") {
            return nil
        } else {
            rawPath = link.removingPercentEncoding ?? link
        }
        var candidates: [(path: String, line: Int?)] = [(rawPath, nil)]
        if let match = rawPath.wholeMatch(of: /(.+?):(\d+)(?::\d+)?/) {
            candidates.append((String(match.1), Int(match.2)))
        }
        for (path, line) in candidates {
            let resolved: [URL]
            if path.hasPrefix("/") {
                resolved = [URL(filePath: path)]
            } else if path == "~" || path.hasPrefix("~/") {
                resolved = [URL(filePath: (path as NSString).expandingTildeInPath)]
            } else {
                resolved = roots.map { URL(filePath: $0, directoryHint: .isDirectory).appending(path: path) }
            }
            for url in resolved.map(\.standardizedFileURL) {
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                      !isDirectory.boolValue, access.allows(url) else { continue }
                return (url.filePath, line)
            }
        }
        return nil
    }

    private static func availableURL(named name: String, in folder: URL) -> URL {
        var url = folder.appending(path: name)
        var suffix = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appending(path: "\(name) \(suffix)")
            suffix += 1
        }
        return url
    }
}

private extension FileRequest {
    /// The paths the request touches, which must all be inside the project.
    var paths: [String] {
        switch self {
        case .list(let path), .read(let path), .write(let path, _), .rename(let path, _),
             .duplicate(let path), .trash(let path):
            [path]
        case .find(let root, _), .search(let root, _):
            [root]
        case .create(let folder, _):
            [folder]
        case .resolveLink(_, let directory):
            directory.map { [$0] } ?? []
        }
    }

    var changesFiles: Bool {
        switch self {
        case .list, .find, .search, .read, .resolveLink: false
        case .write, .create, .rename, .duplicate, .trash: true
        }
    }
}
