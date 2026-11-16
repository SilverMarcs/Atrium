import Foundation

/// A shell command an agent ran, read for what it did to repositories: the
/// folders it committed, pushed or opened a pull request in, and the pull
/// requests it opened. Quoted text, comments and heredoc bodies are text the
/// command carries, not commands it runs, so `echo "gh pr create"` or a
/// search for it opens nothing.
nonisolated struct AgentShellCommand: Equatable, Sendable {
    /// A command the script runs: its words, unquoted, and its text as written.
    private struct Segment: Equatable, Sendable {
        var words: [String] = []
        var text = ""
        /// How many subshells and substitutions deep it runs.
        var depth = 0
    }

    private let segments: [Segment]
    private let directory: String?

    /// `directory` is the folder the command started in.
    init(_ script: String, directory: String?) {
        segments = Self.segments(of: Self.withoutHeredocBodies(script))
        self.directory = directory
    }

    /// A command as Codex records it: its arguments, often a shell running a script.
    init(arguments: [String], directory: String?) {
        let isShell = arguments.count == 3 && ["-c", "-lc"].contains(arguments[1])
            && ["sh", "bash", "zsh"].contains(URL(filePath: arguments[0]).lastPathComponent)
        self.init(isShell ? arguments[2] : arguments.joined(separator: " "), directory: directory)
    }

    /// Whether it might do anything read here, cheaply, before it's parsed.
    static func mightMatter(_ script: String) -> Bool {
        script.contains("gh ") || script.contains("git") && (script.contains("commit") || script.contains("push"))
    }

    // MARK: - What it did

    /// The folders it committed, pushed or opened a pull request in, following
    /// its `cd`s and `git -C`. Relative ones are left out when it's not known
    /// where it started.
    var repositoryFolders: [String] {
        var folders: [String] = []
        var directories = [directory]
        for segment in segments {
            directories.removeLast(max(0, directories.count - segment.depth - 1))
            while directories.count < segment.depth + 1 { directories.append(directories.last ?? nil) }
            let words = Self.command(segment.words)
            let current = directories[directories.count - 1]
            if words.first == "cd" {
                directories[directories.count - 1] = Self.resolve(words.dropFirst().first ?? "~", in: current)
            } else if let folder = Self.gitFolder(words, in: current) ?? (Self.isCreate(words) ? current : nil) {
                if !folders.contains(folder) { folders.append(folder) }
            }
        }
        return folders
    }

    /// The pull requests it opened, as its output names them: URLs on lines of
    /// their own, from a command that runs `gh pr create`. One the command
    /// also names, as `gh pr view 12` does, existed before it ran; and when it
    /// also lists pull requests, or prints more URLs than it opens, its output
    /// proves nothing.
    func openedPullRequests(output: String) -> [URL] {
        let commands = segments.map { Self.command($0.words) }
        let creates = commands.filter(Self.isCreate).count
        guard creates > 0, !commands.contains(where: Self.listsPullRequests) else { return [] }
        let otherText = zip(segments, commands).filter { !Self.isCreate($0.1) }.map(\.0.text).joined(separator: "\n")
        let named = Set(otherText.split(whereSeparator: { $0.isWhitespace || "#/=()\"';&|".contains($0) }).map(String.init))
        var opened: [URL] = []
        for line in output.split(whereSeparator: \.isNewline) {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard let match = text.wholeMatch(of: Self.pullRequestURL), !named.contains(String(match.output.1)),
                  let url = URL(string: text), !opened.contains(url) else { continue }
            opened.append(url)
        }
        return opened.count > creates ? [] : opened
    }

    private static var pullRequestURL: Regex<(Substring, Substring)> {
        /https:\/\/github\.com\/[\w.-]+\/[\w.-]+\/pull\/(\d+)/
    }

    // MARK: - Commands

    /// The words that run, past assignments and wrappers such as `env` or `timeout 60`.
    private static func command(_ words: [String]) -> ArraySlice<String> {
        var words = words[...]
        while let first = words.first {
            if ["env", "time", "nohup", "command", "exec", "do", "then", "else", "{", "!"].contains(first)
                || first.wholeMatch(of: /\w+=.*/) != nil {
                words = words.dropFirst()
            } else if first == "timeout" {
                words = words.dropFirst(2)
            } else {
                break
            }
        }
        return words
    }

    private static func isGitHub(_ words: ArraySlice<String>) -> Bool {
        words.first.map { URL(filePath: $0).lastPathComponent == "gh" } ?? false
    }

    private static func isCreate(_ words: ArraySlice<String>) -> Bool {
        guard isGitHub(words) else { return false }
        let rest = Array(words.dropFirst().prefix(2))
        return rest == ["pr", "create"] || rest == ["pr", "new"]
    }

    /// Commands that print other pull requests' URLs.
    private static func listsPullRequests(_ words: ArraySlice<String>) -> Bool {
        guard isGitHub(words) else { return false }
        let rest = Array(words.dropFirst().prefix(2))
        return rest == ["pr", "list"] || rest == ["pr", "status"] || rest == ["search", "prs"] || rest.first == "api"
    }

    /// Where a `git commit` or `git push` runs.
    private static func gitFolder(_ words: ArraySlice<String>, in directory: String?) -> String? {
        guard words.first.map({ URL(filePath: $0).lastPathComponent == "git" }) == true else { return nil }
        var folder = directory
        var rest = words.dropFirst()
        while let option = rest.first, option.hasPrefix("-") {
            rest = rest.dropFirst()
            if option == "-C", let path = rest.first {
                folder = resolve(path, in: folder)
                rest = rest.dropFirst()
            } else if option == "-c" {
                rest = rest.dropFirst()
            }
        }
        guard let subcommand = rest.first, subcommand == "commit" || subcommand == "push" else { return nil }
        return folder
    }

    private static func resolve(_ path: String, in directory: String?) -> String? {
        guard !path.contains("$") else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
        let expanded = path == "~" ? home : path.hasPrefix("~/") ? home + path.dropFirst(2) : path
        if expanded.hasPrefix("/") { return URL(filePath: expanded).standardizedFileURL.path(percentEncoded: false) }
        guard let directory, expanded != "-" else { return nil }
        return URL(filePath: directory, directoryHint: .isDirectory).appending(path: expanded).standardizedFileURL.path(percentEncoded: false)
    }

    // MARK: - Parsing

    /// The script without the bodies of its heredocs.
    private static func withoutHeredocBodies(_ script: String) -> String {
        var kept: [Substring] = []
        var delimiter: String?
        for line in script.split(separator: "\n", omittingEmptySubsequences: false) {
            if let end = delimiter {
                if line.trimmingCharacters(in: .whitespaces) == end { delimiter = nil }
                continue
            }
            kept.append(line)
            delimiter = line.firstMatch(of: /<<-?[ \t]*['"]?(\w+)/).map { String($0.output.1) }
        }
        return kept.joined(separator: "\n")
    }

    /// The commands a script runs, split where a list, pipe, subshell or
    /// substitution separates them outside quotes.
    private static func segments(of script: String) -> [Segment] {
        var segments: [Segment] = []
        var segment = Segment()
        var word: String?
        var depth = 0
        func endWord() {
            if let word { segment.words.append(word) }
            word = nil
        }
        func endSegment() {
            endWord()
            if !segment.words.isEmpty { segments.append(segment) }
            segment = Segment(depth: depth)
        }
        var characters = script.makeIterator()
        while let character = characters.next() {
            switch character {
            case "'":
                segment.text.append(character)
                var quoted = ""
                while let next = characters.next(), next != "'" { quoted.append(next) }
                segment.text += quoted + "'"
                word = (word ?? "") + quoted
            case "\"":
                segment.text.append(character)
                var quoted = ""
                while let next = characters.next(), next != "\"" {
                    if next == "\\", let escaped = characters.next() {
                        quoted.append(escaped)
                        segment.text += "\\" + String(escaped)
                    } else {
                        quoted.append(next)
                        segment.text.append(next)
                    }
                }
                segment.text.append("\"")
                word = (word ?? "") + quoted
            case "\\":
                if let escaped = characters.next(), escaped != "\n" {
                    word = (word ?? "") + String(escaped)
                    segment.text += "\\" + String(escaped)
                }
            case "#" where word == nil:
                while let next = characters.next(), next != "\n" {}
                endSegment()
            case " ", "\t":
                segment.text.append(character)
                endWord()
            case ";", "&", "|", "\n", "`":
                endSegment()
            case "(":
                depth += 1
                endSegment()
            case ")":
                depth = max(0, depth - 1)
                endSegment()
            default:
                segment.text.append(character)
                word = (word ?? "") + String(character)
            }
        }
        endSegment()
        return segments
    }
}
