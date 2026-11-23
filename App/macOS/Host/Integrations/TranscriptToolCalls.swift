import Foundation

nonisolated extension TranscriptToolCall {
    /// The arguments that say what a call works on, in the order one is
    /// picked, across every provider's tools: a command, then what it looks
    /// for, then the file or address, then a name or note.
    private static let argumentKeys = [
        "command", "CommandLine", "cmd",
        "query", "Query", "pattern",
        "file_path", "path", "Path", "AbsolutePath", "TargetFile", "DirectoryPath",
        "url", "Url",
        "title", "description", "skill", "subject", "name",
    ]

    /// Arguments can be whole files or scripts, so only the first line is kept, cut short.
    private static let argumentLimit = 200

    /// A call by its provider's name, with the first of `argumentKeys` its arguments have.
    init?(name: String?, arguments: Any?) {
        guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
        let arguments = arguments as? [String: Any] ?? [:]
        let argument = Self.argumentKeys.lazy.compactMap { Self.line(arguments[$0]) }.first
        self.init(name: name, argument: argument)
    }

    private static func line(_ value: Any?) -> String? {
        // Antigravity's saved history keeps some arguments as JSON strings.
        guard let text = AntigravityHistory.decodeArg(value),
              let line = text.split(whereSeparator: \.isNewline).lazy
            .map({ $0.trimmingCharacters(in: .whitespaces) }).first(where: { !$0.isEmpty }) else { return nil }
        return line.count > argumentLimit ? String(line.prefix(argumentLimit)) + "…" : line
    }
}
