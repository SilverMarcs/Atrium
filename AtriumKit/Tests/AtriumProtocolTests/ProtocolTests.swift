@testable import AtriumProtocol
import Foundation
import Testing

struct ProtocolTests {
    @Test func providerDefaultsAreOptionalOnTheWire() throws {
        let old = try HostCodec.decode(WireProvider.self, from: Data(#"{"provider":"codex","isEnabled":true,"deletionMessage":""}"#.utf8))
        #expect(old.defaultSettings == nil)
        var provider = old
        provider.defaultSettings = TaskStartSettings(model: "chosen", reasoningEffort: "high", isFastMode: true)
        #expect(try HostCodec.decode(WireProvider.self, from: HostCodec.encode(provider)) == provider)
    }

    @Test func framesCarryTheirKey() throws {
        let key = UUID()
        let frame = try HostCodec.decode(ClientFrame.self, from: HostCodec.encode(
            ClientFrame(id: 3, request: .interrupt(taskID: "t"), key: key)
        ))
        #expect(frame.id == 3)
        #expect(frame.key == key)
        guard case .interrupt(let taskID) = frame.request else { Issue.record("Wrong request"); return }
        #expect(taskID == "t")
    }

    @Test func framesWithoutAKeyOrWithUnknownRequestsStillDecode() throws {
        let frame = try HostCodec.decode(ClientFrame.self, from: Data(#"{"id":1,"request":{"somethingNew":{}}}"#.utf8))
        #expect(frame.key == nil)
        guard case .unsupported = frame.request else { Issue.record("Expected unsupported"); return }
    }

    @Test func pairingLinksRoundTrip() throws {
        let link = PairingLink(hostID: "abcdefghijklmnop", publicKey: Data(repeating: 7, count: 32), secret: "s3cret", hostName: "Studio")
        let url = try #require(link.url)
        #expect(PairingLink(url: url) == link)
        #expect(PairingLink(url: URL(string: "atrium://pair?v=2&host=x")!) == nil)
    }

    @Test func transcriptsKeepMessagesTheWindowMovedPast() {
        let messages = ["a", "b", "c", "d"].map { TranscriptMessage(id: $0, role: .user, blocks: []) }
        let window = ["c", "d", "e"].map { TranscriptMessage(id: $0, role: .user, blocks: []) }
        #expect(messages.extended(by: window).map(\.id) == ["a", "b", "c", "d", "e"])
        // A window that no longer reaches anything kept replaces it.
        let unrelated = [TranscriptMessage(id: "x", role: .user, blocks: [])]
        #expect(messages.extended(by: unrelated).map(\.id) == ["x"])
    }

    @Test func tasksDeltasApplyToSnapshots() {
        func task(_ id: String, _ title: String) -> WireTask {
            WireTask(
                id: id, title: title, provider: .codex, status: .idle, projectName: "", directory: "",
                updatedAt: .now, hasUnreadResult: false, isSettled: false, supportsDeletion: true, actions: []
            )
        }
        let old = WireTasksSnapshot(tasks: [task("1", "One"), task("2", "Two")], workspaces: [], providers: [])
        let new = WireTasksSnapshot(tasks: [task("2", "Second"), task("3", "Three")], workspaces: [], providers: [])
        var applied = old
        applied.apply(WireTasksDelta(from: old, to: new))
        #expect(applied.tasks.map(\.title) == ["Second", "Three"])
    }
}
