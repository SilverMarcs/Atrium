import AtriumProtocol
import Foundation
import Testing

struct TerminalFrameTests {
    @Test func checkpointAndDeltaRoundTripPreserveStyledUnicodeAndEvictHistory() throws {
        let original = frame(sequence: 1, first: 0, screen: 1, contents: ["history", "\u{1B}[31m你好 👩🏽‍💻\u{1B}[0m", "prompt"])
        let next = frame(id: original.terminalID, sequence: 2, first: 1, screen: 2, contents: [original.lines[1].content, "done", "new prompt"])
        let checkpoint = try #require(original.applying(to: nil))
        let delta = next.changes(since: original)
        #expect(delta.baseSequence == 1)
        #expect(delta.lines.map(\.row) == [2, 3])
        let decoded = try HostCodec.decode(WireTerminalFrame.self, from: HostCodec.encode(delta))
        #expect(decoded.applying(to: checkpoint) == next)
    }

    @Test func missedUpdatesAndReplacedProcessesRequireCheckpoints() {
        let original = frame(sequence: 1)
        let next = frame(id: original.terminalID, sequence: 3)
        var missed = next.changes(since: original)
        missed.baseSequence = 2
        #expect(missed.applying(to: original) == nil)
        #expect(next.changes(since: frame(sequence: 2)).baseSequence == nil)
        #expect(next.applying(to: original) == next)
    }

    @Test func malformedGridsAndDuplicateRowsAreRejected() {
        var invalid = frame(sequence: 1)
        invalid.lines.append(invalid.lines[0])
        #expect(invalid.applying(to: nil) == nil)
        invalid = frame(sequence: 1)
        invalid.rows = 0
        #expect(invalid.applying(to: nil) == nil)
        invalid = frame(sequence: 1)
        invalid.screenRow = Int.max
        #expect(invalid.applying(to: nil) == nil)
        invalid = frame(sequence: 1)
        invalid.cursorRow = 999
        #expect(invalid.applying(to: nil) == nil)
    }

    @Test func terminalTopicsAndProcessBoundInputSurviveWireEncoding() throws {
        let topic = HostTopic.terminal(taskID: "task")
        #expect(try HostCodec.decode(HostTopic.self, from: HostCodec.encode(topic)) == topic)
        let id = UUID()
        let bytes = Data([0x1B, 0x5B, 0x41, 0x03])
        let request = HostRequest.terminal(taskID: "task", action: .input(terminalID: id, data: bytes))
        let decoded = try HostCodec.decode(HostRequest.self, from: HostCodec.encode(request))
        guard case .terminal("task", .input(let target, let data)) = decoded else {
            Issue.record("Expected task terminal input"); return
        }
        #expect(target == id)
        #expect(data == bytes)
    }

    @Test func clearedScrollbackRequiresDisplayRestoration() {
        let original = frame(sequence: 1, first: 0, screen: 1, contents: ["old history", "screen", "prompt"])
        let cleared = frame(id: original.terminalID, sequence: 2, first: 1, screen: 1, contents: ["screen", "prompt"])
        #expect(cleared.presentation(since: original).hasPrefix("\u{1B}c"))
    }

    private func frame(id: UUID = UUID(), sequence: UInt64, first: Int = 0, screen: Int = 0,
                       contents: [String] = ["first", "second"]) -> WireTerminalFrame {
        WireTerminalFrame(terminalID: id, sequence: sequence, columns: 80, rows: 2,
                          firstRow: first, screenRow: screen, cursorRow: screen + 1, cursorColumn: 0,
                          isAlternate: false, inputModes: "", hasExited: false,
                          lines: contents.enumerated().map { WireTerminalLine(row: first + $0.offset, content: $0.element) })
    }
}
