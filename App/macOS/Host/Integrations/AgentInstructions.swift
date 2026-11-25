import Foundation

/// What Atrium tells the agents it runs: Claude appends it to its system
/// prompt, Codex takes it as developer instructions and Antigravity appends it
/// to its own. It holds only what no tool says, as each tool's description
/// says how to use it.
@MainActor
struct AgentInstructions {
    /// The folders of the project a chat's folder belongs to, and which of
    /// them the chat works in, for a folder in a project.
    var projectFolders: (String) -> (all: [String], own: String)? = { _ in nil }

    /// A chat's instructions: the base, then its project's other folders when
    /// it has any, last so the rest of the prompt stays cached when they change.
    func text(directory: String) -> String {
        let others = otherFolders(for: directory)
        return others.isEmpty ? Self.base : Self.base + "\n\n" + Self.folders(working: directory, others: others)
    }

    /// The project's folders besides the one a chat works in, which it may also change.
    func otherFolders(for directory: String) -> [String] {
        guard let folders = projectFolders(directory) else { return [] }
        return folders.all.filter { $0 != folders.own }
    }

    /// Names the folders a project spans beside the one the agent works in.
    private static func folders(working directory: String, others: [String]) -> String {
        let lines = ([directory] + others).map { path in
            let kind = GitCheckout(rootedAt: URL(filePath: path, directoryHint: .isDirectory)) == nil ? "folder" : "Git repository"
            return "- \(URL(filePath: path).lastPathComponent) (\(kind)): `\(path)`"
        }
        return """
            ## Project folders

            This project spans several folders. You work in the first; the others are part of the project too, and you may read and change them. Run Git commands inside the repository you change, and commit each repository on its own.

            \(lines.joined(separator: "\n"))
            """
    }

    private static let base = """
        # Diffs

        Diffs shows this chat to the user on Mac, iPad and iPhone.

        To show an image, such as a screenshot, plot or generated picture, put it in your reply as Markdown: `![short caption](/absolute/path.png)`. It loads from this Mac on every device whenever the chat is viewed, so give each image its own file name and leave it in place: overwriting or deleting the file changes or breaks earlier messages.
        """
}
