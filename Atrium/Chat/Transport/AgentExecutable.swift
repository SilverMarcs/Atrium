import Foundation

enum AgentExecutable {
    static func resolve(_ name: String) throws -> (URL, [String: String]) {
        var environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let paths = [home + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
            + (environment["PATH"] ?? "/usr/bin:/bin").split(separator: ":").map(String.init)
        environment["PATH"] = paths.joined(separator: ":")
        for directory in paths {
            let url = URL(filePath: directory).appending(path: name)
            if FileManager.default.isExecutableFile(atPath: url.path) { return (url, environment) }
        }
        throw AgentError(message: "Could not find \(name) in PATH: \(environment["PATH"] ?? "")")
    }
}
