import Darwin
import Foundation

/// Both providers trust the checkout root, including the main checkout for linked worktrees.
@MainActor
enum AgentWorkspaceTrust {
    static func folders(in directory: String) async -> [String] {
        let folder = URL(filePath: directory).standardizedFileURL.resolvingSymlinksInPath()
        var root = folder
        if let output = try? await IntegrationProcess.run(
            "git", arguments: ["rev-parse", "--path-format=absolute", "--show-toplevel", "--git-common-dir"],
            directory: folder.path
        ) {
            let paths = String(decoding: output, as: UTF8.self).split(separator: "\n")
            if let checkout = paths.first {
                root = URL(filePath: String(checkout))
                if paths.count == 2 {
                    let common = URL(filePath: String(paths[1]))
                    if common.lastPathComponent == ".git" { root = common.deletingLastPathComponent() }
                }
            }
        }
        var paths = [root.standardizedFileURL.resolvingSymlinksInPath().path.precomposedStringWithCanonicalMapping]
        // Foundation can collapse /private/var to /var; native providers can retain realpath's spelling.
        if let resolved = root.path.withCString({ realpath($0, nil) }) {
            defer { free(resolved) }
            let path = String(cString: resolved).precomposedStringWithCanonicalMapping
            if !paths.contains(path) { paths.append(path) }
        }
        return paths
    }
}
