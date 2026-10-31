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

    @Test func pageBlocksRoundTrip() throws {
        let blocks: [TranscriptBlock] = [
            .text("Here", id: "1"), .tools(count: 2, id: "2"),
            .page(TranscriptPage(key: "abc", title: "Revenue"), id: "3")
        ]
        #expect(try HostCodec.decode([TranscriptBlock].self, from: HostCodec.encode(blocks)) == blocks)
        let encoded = String(decoding: try HostCodec.encode(blocks[2]), as: UTF8.self)
        #expect(encoded.contains(#""page":{"#))
    }

    @Test func reportBlocksRoundTrip() throws {
        let block = TranscriptBlock.report(.init(name: "Codex · Tests", sessionID: "t"), id: "r")
        #expect(try HostCodec.decode(TranscriptBlock.self, from: HostCodec.encode(block)) == block)
        #expect(String(decoding: try HostCodec.encode(block), as: UTF8.self).contains(#""agent":{"#))
    }

    @Test func reportsFoldIntoTheReplyTheyJoin() {
        let messages = [
            TranscriptMessage(id: "p", role: .user, blocks: [.text("Fix it", id: "p")]),
            TranscriptMessage(id: "a", role: .assistant, blocks: [.tools(count: 1, id: "a.0"), .text("Started two subagents.", id: "a.1")]),
            TranscriptMessage(id: "r", role: .user, blocks: [.text("Full report", id: "r")],
                              relay: TranscriptRelay(kind: .results, senders: [.init(name: "Claude · Fix the toolbar"),
                                                                                .init(name: "Codex · Tests")])),
            TranscriptMessage(id: "b", role: .assistant, blocks: [.text("Both done.", id: "b.0")]),
            TranscriptMessage(id: "q", role: .user, blocks: [.text("Thanks", id: "q")])
        ]
        let folded = messages.foldingReports()
        #expect(folded.map(\.id) == ["p", "a", "q"])
        #expect(folded[1].blocks == [
            .tools(count: 1, id: "a.0"), .text("Started two subagents.", id: "a.1"),
            .report(.init(name: "Claude · Fix the toolbar"), id: "r.0"), .report(.init(name: "Codex · Tests"), id: "r.1"),
            .text("Both done.", id: "b.0")
        ])
    }

    @Test func aReportOpeningTheWindowStartsTheReply() {
        let messages = [
            TranscriptMessage(id: "r", role: .user, blocks: [], relay: TranscriptRelay(kind: .results, senders: [.init(name: "Codex · audit")])),
            TranscriptMessage(id: "b", role: .assistant, blocks: [.text("Done.", id: "b.0")]),
            TranscriptMessage(id: "t", role: .user, blocks: [.text("Do this", id: "t")],
                              relay: TranscriptRelay(kind: .task, senders: [.init(name: "Claude · Parent")], taskID: "1"))
        ]
        let folded = messages.foldingReports()
        #expect(folded.map(\.id) == ["r", "t"])
        #expect(folded[0].role == .assistant)
        #expect(folded[0].blocks == [.report(.init(name: "Codex · audit"), id: "r.0"), .text("Done.", id: "b.0")])
    }

    @Test func tasksDeltasApplyToSnapshots() {
        func task(_ id: String, _ title: String) -> WireTask {
            WireTask(
                id: id, title: title, provider: .codex, status: .idle, projectName: "", path: "", directory: "",
                updatedAt: .now, hasUnreadResult: false, isSettled: false, supportsDeletion: true, actions: []
            )
        }
        let old = WireTasksSnapshot(tasks: [task("1", "One"), task("2", "Two")], workspaces: [], providers: [])
        let new = WireTasksSnapshot(tasks: [task("2", "Second"), task("3", "Three")], workspaces: [], providers: [])
        var applied = old
        applied.apply(WireTasksDelta(from: old, to: new))
        #expect(applied.tasks.map(\.title) == ["Second", "Three"])
    }

    @Test func sideChatsStayApartFromDelegatedWork() throws {
        func task(_ id: String, origin: WireTaskOrigin?) -> WireTask {
            WireTask(
                id: id, title: id, provider: .codex, status: .processing, projectName: "", path: "", directory: "",
                updatedAt: .now, hasUnreadResult: false, isSettled: false, supportsDeletion: false, actions: [], origin: origin
            )
        }
        let side = task("side", origin: .sideChat("main"))
        let snapshot = WireTasksSnapshot(
            tasks: [task("main", origin: nil), task("sub", origin: .subagent("main")), side], workspaces: [], providers: []
        )
        #expect(snapshot.children(of: "main").map(\.id) == ["sub"])
        #expect(snapshot.sideChat(of: "main")?.id == "side")
        #expect(snapshot.parent(of: side)?.id == "main")
        #expect(try HostCodec.decode(WireTask.self, from: HostCodec.encode(side)).isSideChat)
    }
}
