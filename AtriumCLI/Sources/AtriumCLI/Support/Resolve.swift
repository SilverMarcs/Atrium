import AtriumClient
import AtriumProtocol
import Foundation

extension HostClient {
    /// A session by its full ID or a prefix only it has.
    func session(_ selector: String) throws -> WireTask {
        let tasks = tasks?.tasks ?? []
        if let task = tasks.first(where: { $0.id == selector }) { return task }
        let matches = tasks.filter { $0.id.hasPrefix(selector) }
        guard matches.count == 1 else {
            throw CLIError(
                matches.isEmpty ? .notFound : .ambiguous,
                matches.isEmpty ? "No session on \(name) has the ID “\(selector)”." : "Several sessions on \(name) start with “\(selector)”; use more of the ID."
            )
        }
        return matches[0]
    }

    /// A project by its ID or a prefix of it, its name, or its folder.
    func project(_ selector: String) throws -> WireWorkspace {
        let workspaces = tasks?.workspaces ?? []
        let exact = workspaces.filter {
            $0.id.uuidString.caseInsensitiveCompare(selector) == .orderedSame
                || $0.name.caseInsensitiveCompare(selector) == .orderedSame
                || $0.path == selector || $0.directory == selector
        }
        if exact.count == 1 { return exact[0] }
        let prefixed = exact.isEmpty ? workspaces.filter { $0.id.uuidString.lowercased().hasPrefix(selector.lowercased()) } : []
        if prefixed.count == 1 { return prefixed[0] }
        let count = exact.count + prefixed.count
        throw CLIError(
            count == 0 ? .notFound : .ambiguous,
            count == 0 ? "No project on \(name) matches “\(selector)”. List them with `atrium projects`." : "Several projects on \(name) match “\(selector)”; use its ID."
        )
    }

    func json(_ task: WireTask) -> SessionJSON {
        SessionJSON(task, workspace: workspace(task.workspaceID))
    }
}

/// Reads a prompt from its argument, or from standard input when it's "-" or absent.
func readPrompt(_ argument: String?) throws -> String {
    let text: String
    if let argument, argument != "-" {
        text = argument
    } else {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        text = String(decoding: data, as: UTF8.self)
    }
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw CLIError(.invalidArgument, "The prompt is empty.")
    }
    return text
}

/// Loads JPEG images to attach to a prompt, which is the format hosts accept.
func readImages(_ paths: [String]) throws -> [Data] {
    guard paths.count <= 10 else { throw CLIError(.invalidArgument, "Attach up to 10 images at a time.") }
    return try paths.map { path in
        guard let data = FileManager.default.contents(atPath: path) else {
            throw CLIError(.invalidArgument, "Couldn’t read the image at \(path).")
        }
        guard data.starts(with: [0xFF, 0xD8, 0xFF]) else {
            throw CLIError(.invalidArgument, "\(path) isn’t a JPEG image; hosts accept JPEG attachments only.")
        }
        return data
    }
}

/// A delivery key from `--id`: any UUID, kept by the caller to repeat a
/// prompt or start safely after an unknown outcome.
func deliveryKey(_ id: String?) throws -> UUID {
    guard let id else { return UUID() }
    guard let key = UUID(uuidString: id) else { throw CLIError(.invalidArgument, "--id must be a UUID, such as \(UUID().uuidString).") }
    return key
}

extension UUID {
    /// Another key derived from this one, for the second request of a command
    /// that sends two, so repeating the command repeats both keys.
    func derived(_ salt: UInt8) -> UUID {
        var bytes = uuid
        bytes.0 ^= salt
        bytes.6 = (bytes.6 & 0x0F) | 0x40
        return UUID(uuid: bytes)
    }
}
