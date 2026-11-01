import AtriumClient
import AtriumProtocol
import Foundation

/// This Mac's own host, for the client bundled in Atrium.app: it connects to
/// the app it's inside through the socket that app keeps for the agents it
/// runs. The socket is only this user's to open, so there's nothing to pair.
enum LocalHost {
    #if os(macOS)
    /// The app this client is bundled in, at `Atrium.app/Contents/Helpers/atrium`.
    static let app: Bundle? = {
        guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return nil }
        let contents = executable.deletingLastPathComponent().deletingLastPathComponent()
        let app = contents.deletingLastPathComponent()
        guard contents.lastPathComponent == "Contents", app.pathExtension == "app" else { return nil }
        return Bundle(url: app)
    }()

    static var socket: URL? {
        app?.bundleIdentifier.map { HostProtocol.localAgentsSocket(appBundleIdentifier: $0) }
    }

    /// The version of the app this client came with.
    static var version: String? {
        app?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    /// Tells apart a host that isn't listening from a sandbox that keeps this
    /// command from reaching it, which the agent can ask to run outside.
    static func checkReachable() throws {
        guard let socket else { return }
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = Array(socket.path(percentEncoded: false).utf8CString)
        guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else { return }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            path.withUnsafeBytes { buffer.copyMemory(from: $0) }
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result != 0 else { return }
        switch errno {
        case EPERM, EACCES:
            throw CLIError(.unreachable, """
                A sandbox keeps atrium from reaching Atrium on this Mac. Run the command outside the sandbox \
                (with escalated permissions); it only talks to Atrium.
                """)
        default:
            throw unreachable
        }
    }
    #else
    static var socket: URL? { nil }
    static var version: String? { nil }
    static func checkReachable() throws {}
    #endif

    static var name: String { Client.defaultDeviceName }

    static var unreachable: CLIError {
        CLIError(.unreachable, """
            Atrium on this Mac isn’t taking commands from agents: it isn’t running, or the Orchestrator is off \
            in Atrium Settings → Integrations. Only the user can turn it on.
            """)
    }
}

/// The agent session a command runs in, as far as this Mac tells: Claude and
/// Codex export their session's ID to every command they run. Commands
/// inherit them, so a command Codex runs inside a Claude session sees both.
/// The nearest agent among this process's ancestors goes first, and the host
/// takes the first one that's working.
enum Caller {
    static let candidates: [String] = {
        let environment = ProcessInfo.processInfo.environment
        let ids = [("claude", "CLAUDE_CODE_SESSION_ID"), ("codex", "CODEX_THREAD_ID")].compactMap { provider, variable in
            environment[variable].flatMap { $0.isEmpty ? nil : (provider, "\(provider):\($0)") }
        }
        let nearest = ancestorAgents()
        return ids.sorted { (nearest.firstIndex(of: $0.0) ?? .max) < (nearest.firstIndex(of: $1.0) ?? .max) }.map(\.1)
    }()

    /// The agents running this process, nearest first, by their processes' names.
    private static func ancestorAgents() -> [String] {
        #if os(macOS)
        var agents: [String] = []
        var pid = getppid()
        while pid > 1 {
            var info = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 else { break }
            let name = withUnsafeBytes(of: info.pbi_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            if ["claude", "codex"].contains(name), !agents.contains(name) { agents.append(name) }
            pid = pid_t(info.pbi_ppid)
        }
        return agents
        #else
        return []
        #endif
    }
}
