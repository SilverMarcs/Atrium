import Foundation

/// The files Codex threads changed, the repositories their commands worked
/// in and the folder they last ran one in, read from their rollouts off the
/// main actor.
actor CodexRolloutEdits {
    struct Work: Sendable {
        var edits = AgentEdits()
        /// The folder the thread's newest command ran in. Codex runs each
        /// command in the folder it names, so an agent works in a worktree
        /// while its thread stays in the main checkout; and one that changes
        /// files with its own scripts, not patches, leaves no edit saying so.
        var directory: String?
    }

    private var scans: [String: JSONLines.Scan<Work>] = [:]

    private static let marker = #""item":{"type":"FileChange""#

    func work(atPath path: String) -> Work? {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int else { return nil }
        var scan = scans[path] ?? JSONLines.Scan(Work())
        try? scan.read(URL(filePath: path), size: size) { data, range, work in
            JSONLines.forEachLine(containing: Self.marker, in: data, range, newestFirst: false) { line in
                Self.record(data[line], into: &work.edits)
                return true
            }
            JSONLines.forEachLine(containing: Self.commandMarker, in: data, range, newestFirst: false) { line in
                Self.recordCommand(data[line], into: &work.edits)
                return true
            }
            JSONLines.forEachLine(containing: Self.commandMarker, in: data, range, newestFirst: true) { line in
                guard let directory = Self.directory(ofCommand: data[line]) else { return true }
                work.directory = directory
                return false
            }
        }
        scans[path] = scan
        return scan.state
    }

    private static let commandMarker = #""item":{"type":"CommandExecution""#

    /// A finished command, with the output that says what it opened.
    private static func recordCommand(_ line: Data, into edits: inout AgentEdits) {
        guard AgentShellCommand.mightMatter(String(decoding: line, as: UTF8.self)),
              let record = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let item = (record["payload"] as? [String: Any])?["item"] as? [String: Any],
              item["type"] as? String == "CommandExecution",
              let output = item["aggregated_output"] as? String,
              let date = (record["timestamp"] as? String)
                .flatMap({ try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse($0) }) else { return }
        let directory = (item["cwd"] as? String).map(Self.path)
        let command = (item["command"] as? [String]).map { AgentShellCommand(arguments: $0, directory: directory) }
            ?? (item["command"] as? String).map { AgentShellCommand($0, directory: directory) }
        if let command { edits.record(command, output: output, at: date) }
    }

    /// The folder a finished command ran in.
    private static func directory(ofCommand line: Data) -> String? {
        guard let record = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let item = (record["payload"] as? [String: Any])?["item"] as? [String: Any],
              item["type"] as? String == "CommandExecution",
              let cwd = item["cwd"] as? String else { return nil }
        let folder = path(cwd)
        return folder.hasPrefix("/") ? folder : nil
    }

    /// A folder as Codex records it: a file URL or a path.
    private static func path(_ cwd: String) -> String {
        URL(string: cwd)?.path(percentEncoded: false) ?? cwd
    }

    /// Forgets the rollouts of threads deleted since.
    func dropDeleted() {
        scans = scans.filter { FileManager.default.fileExists(atPath: $0.key) }
    }

    /// A completed file change names each file it touched, and where one moved to.
    private static func record(_ line: Data, into edits: inout AgentEdits) {
        guard let record = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let item = (record["payload"] as? [String: Any])?["item"] as? [String: Any],
              item["type"] as? String == "FileChange",
              let changes = item["changes"] as? [String: Any],
              let date = (record["timestamp"] as? String)
                .flatMap({ try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse($0) }) else { return }
        for (path, change) in changes {
            edits.record(file: path, at: date)
            if let moved = (change as? [String: Any])?["move_path"] as? String { edits.record(file: moved, at: date) }
        }
    }
}
