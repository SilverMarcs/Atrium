import AtriumProtocol
import Foundation

/// What a project of selected folders reaches and follows tasks into, on real
/// repositories: two siblings, a linked worktree of one, a repository nested
/// in it that isn't selected, and a plain folder.
@main
struct ProjectFolderChecks {
    struct Failure: Error { let message: String }

    static func main() {
        do {
            let root = URL(filePath: CommandLine.arguments[1], directoryHint: .isDirectory).resolvingSymlinksInPath()
            try findsOnlySelectedRepositories(in: root)
            try reachesSelectedFoldersAndTheirWorktrees(in: root)
            print("Project folder checks passed")
        } catch let failure as Failure {
            print("FAIL: \(failure.message)")
            exit(1)
        } catch {
            print("FAIL: \(error)")
            exit(1)
        }
    }

    static func findsOnlySelectedRepositories(in root: URL) throws {
        let api = root.appending(path: "api").filePath
        let web = root.appending(path: "web").filePath
        let notes = root.appending(path: "notes").filePath
        let repositories = GitCheckout.repositories(of: [api, web, notes])
        try check(repositories == [api, web], "the selected repositories are followed: \(repositories)")

        // Where a task's edits land, as TasksFeed locates their checkouts.
        func followed(_ path: String) -> Bool {
            GitCheckout(containing: root.appending(path: path)).map { repositories.contains($0.mainCheckoutURL.filePath) } ?? false
        }
        try check(followed("api/src"), "an edit in the primary repository is followed")
        try check(followed("web/src"), "an edit in a sibling repository is followed")
        try check(followed("api-feature/src"), "an edit in a worktree of a selected repository is followed")
        try check(!followed("api/vendor/lib"), "an edit in an unselected nested repository isn't followed")
        try check(!followed("other"), "an edit in an unselected repository isn't followed")

        let submodule = root.appending(path: "web/modules/other").filePath
        try check(GitCheckout.repositories(of: [submodule]) == [submodule], "a selected submodule is a repository of its own")
        try check(!followed("web/modules/other/src"), "an edit in an unselected submodule isn't followed")

        try check(GitCheckout(rootedAt: root.appending(path: "api/src")) == nil, "a subfolder of a repository isn't one")
        try check(GitCheckout(rootedAt: root.appending(path: "api-feature"))?.mainCheckoutURL.filePath == api,
                  "a worktree's top folder belongs to its repository")
    }

    static func reachesSelectedFoldersAndTheirWorktrees(in root: URL) throws {
        let access = WorkspaceAccess(folders: ["api", "web", "notes"].map { root.appending(path: $0).filePath })
        try check(access.allows(root.appending(path: "web/src/app.ts")), "a sibling repository's files are reachable")
        try check(access.allows(root.appending(path: "notes/todo.md")), "a plain folder's files are reachable")
        try check(access.allows(root.appending(path: "api-feature/src")), "a selected repository's worktree is reachable")
        try check(!access.allows(root.appending(path: "other/README")), "an unselected repository isn't reachable")
        try check(!access.allows(root.appending(path: "api/../other")), "a path can't climb out")
    }

    static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }
}
