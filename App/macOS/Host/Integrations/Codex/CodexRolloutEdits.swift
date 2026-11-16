import Foundation

/// The files Codex threads changed and the repositories their commands
/// worked in, read from their rollouts off the main actor.
actor CodexRolloutEdits {
    private var scans: [String: JSONLines.Scan<AgentEdits>] = [:]

    private static let marker = #""item":{"type":"FileChange""#

    func edits(atPath path: String) -> AgentEdits? {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int else { return nil }
        var scan = scans[path] ?? JSONLines.Scan(AgentEdits())
        try? scan.read(URL(filePath: path), size: size) { data, range, edits in
            JSONLines.forEachLine(containing: Self.marker, in: data, range, newestFirst: false) { line in
                Self.record(data[line], into: &edits)
                return true
            }
            JSONLines.forEachLine(containing: Self.commandMarker, in: data, range, newestFirst: false) { line in
                Self.recordCommand(data[line], into: &edits)
                return true
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
        let directory = (item["cwd"] as? String).map { URL(string: $0)?.path(percentEncoded: false) ?? $0 }
        let command = (item["command"] as? [String]).map { AgentShellCommand(arguments: $0, directory: directory) }
            ?? (item["command"] as? String).map { AgentShellCommand($0, directory: directory) }
        if let command { edits.record(command, output: output, at: date) }
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
