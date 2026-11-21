import AtriumProtocol
import Foundation
import LegacyAtriumProtocol

@main
struct ProviderCompatibilityChecks {
    static func main() throws {
        try check(AtriumProtocol.AgentProvider.allCases.map(\.rawValue) == ["codex", "claude"],
                  "Only supported providers are offered")
        let workspaceID = UUID()
        let key = UUID()
        for provider in [LegacyAtriumProtocol.AgentProvider.codex, .claude, .jcode] {
            let frame = LegacyAtriumProtocol.ClientFrame(
                id: 7, request: .compose(provider: provider, workspaceID: workspaceID), key: key)
            let decoded = try AtriumProtocol.HostCodec.decode(
                AtriumProtocol.ClientFrame.self, from: LegacyAtriumProtocol.HostCodec.encode(frame))
            try check(decoded.id == 7 && decoded.key == key, "Request identity survives decoding")
            if provider == .jcode {
                guard case .unsupported = decoded.request else { throw Failure(message: "Retired provider must be unsupported") }
            } else {
                guard case .compose(let received, let workspace, _, _) = decoded.request else {
                    throw Failure(message: "Supported compose must still decode")
                }
                try check(received.rawValue == provider.rawValue && workspace == workspaceID, "Supported compose is unchanged")
            }
        }
        let fork = LegacyAtriumProtocol.ClientFrame(id: 8, request: .task(id: "codex:one", action: .fork(into: .jcode)))
        let decoded = try AtriumProtocol.HostCodec.decode(
            AtriumProtocol.ClientFrame.self, from: LegacyAtriumProtocol.HostCodec.encode(fork))
        guard case .unsupported = decoded.request else { throw Failure(message: "Retired fork must be unsupported") }
        let response = AtriumProtocol.ServerFrame.reply(id: decoded.id, reply: .unsupported)
        let legacyResponse = try LegacyAtriumProtocol.HostCodec.decode(
            LegacyAtriumProtocol.ServerFrame.self, from: AtriumProtocol.HostCodec.encode(response))
        guard case .reply(id: 8, reply: .failed(let message)) = legacyResponse, !message.isEmpty else {
            throw Failure(message: "Legacy client must recognize unsupported reply")
        }
        let snapshot = AtriumProtocol.WireTasksSnapshot(tasks: [], workspaces: [], providers:
            AtriumProtocol.AgentProvider.allCases.map {
                AtriumProtocol.WireProvider(provider: $0, isAvailable: true, deletionMessage: "Delete")
            })
        let event = AtriumProtocol.ServerFrame.event(.tasks(snapshot))
        let legacyEvent = try LegacyAtriumProtocol.HostCodec.decode(
            LegacyAtriumProtocol.ServerFrame.self, from: AtriumProtocol.HostCodec.encode(event))
        guard case .event(.tasks(let received)) = legacyEvent else { throw Failure(message: "Legacy snapshot must decode") }
        try check(received.providers.filter(\.isAvailable).map { $0.provider.rawValue } == ["codex", "claude"],
                  "Legacy client receives only the host's remaining providers")
        try olderHost()
        try pageImageRequests()
        try retainedThreads()
        print("Provider compatibility checks passed")
    }

    static func pageImageRequests() throws {
        let request = AtriumProtocol.ClientFrame(id: 9, request:
            .image(taskID: "codex:one", path: "/tmp/image.png", maxPixelSize: 2048, pageKey: "page"))
        let old = try LegacyAtriumProtocol.HostCodec.decode(LegacyAtriumProtocol.ClientFrame.self,
            from: AtriumProtocol.HostCodec.encode(request))
        guard case .image(let taskID, let path, let size) = old.request else {
            throw Failure(message: "Older hosts must still decode image requests")
        }
        try check(taskID == "codex:one" && path == "/tmp/image.png" && size == 2048,
                  "A page key must not change fields understood by an older host")
        let legacy = LegacyAtriumProtocol.ClientFrame(id: 10, request:
            .image(taskID: "codex:one", path: "/tmp/image.png", maxPixelSize: 2048))
        let current = try AtriumProtocol.HostCodec.decode(AtriumProtocol.ClientFrame.self,
            from: LegacyAtriumProtocol.HostCodec.encode(legacy))
        guard case .image(_, _, _, nil) = current.request else {
            throw Failure(message: "Older clients must retain image access without a page key")
        }
    }

    static func olderHost() throws {
        let providers = LegacyAtriumProtocol.AgentProvider.allCases.map {
            LegacyAtriumProtocol.WireProvider(provider: $0, isAvailable: true, deletionMessage: "Delete")
        }
        let tasks = LegacyAtriumProtocol.AgentProvider.allCases.map {
            LegacyAtriumProtocol.WireTask(
                id: "\($0.rawValue):one", title: "Task", provider: $0, status: .idle,
                projectName: "Project", path: "/project", directory: "/project", updatedAt: .now,
                hasUnreadResult: false, isSettled: false, supportsDeletion: true, actions: [.prompt])
        }
        let snapshot = LegacyAtriumProtocol.WireTasksSnapshot(tasks: tasks, workspaces: [], providers: providers)
        let received = try AtriumProtocol.HostCodec.decode(
            AtriumProtocol.WireTasksSnapshot.self, from: LegacyAtriumProtocol.HostCodec.encode(snapshot))
        try check(received.tasks.map(\.provider.rawValue) == ["codex", "claude"], "Retired tasks must not hide supported tasks")
        try check(received.providers.map(\.provider.rawValue) == ["codex", "claude"], "Retired providers must not hide supported providers")
        let delta = LegacyAtriumProtocol.WireTasksDelta(
            from: .init(tasks: [], workspaces: [], providers: []), to: snapshot)
        let changes = try AtriumProtocol.HostCodec.decode(
            AtriumProtocol.WireTasksDelta.self, from: LegacyAtriumProtocol.HostCodec.encode(delta))
        try check(changes.upsertedTasks.map(\.provider.rawValue) == ["codex", "claude"], "Mixed-provider deltas remain usable")
        try check(changes.providers?.map(\.provider.rawValue) == ["codex", "claude"], "Provider delta filters retired entries")
        let empty = try AtriumProtocol.HostCodec.decode(AtriumProtocol.WireTasksDelta.self, from: Data("{}".utf8))
        try check(empty.providers == nil && empty.upsertedTasks.isEmpty, "An omitted delta stays omitted")
    }

    static func retainedThreads() throws {
        let threads = [AtriumProtocol.AgentProvider.codex, .claude].map {
            AgentThread(sessionID: $0.rawValue, provider: $0, title: "Retained", directory: "/project",
                        updatedAt: .now, status: .stopped)
        }
        let encoder = JSONEncoder()
        let supported = try encoder.encode(threads)
        var rows = try JSONSerialization.jsonObject(with: supported) as? [[String: Any]] ?? []
        var retired = rows[0]
        retired["provider"] = "jcode"
        rows.insert(retired, at: 1)
        let mixed = try JSONSerialization.data(withJSONObject: rows)
        let restored = try JSONDecoder().decode(RetainedAgentThreads.self, from: mixed)
        try check(restored.threads == threads, "A retired provider must not discard supported retained threads")
        let unsupportedOnly = try JSONSerialization.data(withJSONObject: [retired])
        try check(try JSONDecoder().decode(RetainedAgentThreads.self, from: unsupportedOnly).threads.isEmpty,
                  "An entirely retired collection restores as empty")
        try check(try JSONDecoder().decode(RetainedAgentThreads.self, from: supported).threads == threads,
                  "Supported retained threads preserve their data")
    }

    struct Failure: Error { var message: String }
    static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }
}
