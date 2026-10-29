@testable import AtriumCLI
import AtriumProtocol
import Foundation
import Testing

struct OutputTests {
    @Test func derivedKeysAreStableAndDistinct() {
        let key = UUID()
        #expect(key.derived(1) == key.derived(1))
        #expect(key.derived(1) != key)
        #expect(key.derived(1) != key.derived(2))
    }

    @Test func statusNamesRoundTrip() {
        for status in AgentThreadStatus.allNames {
            #expect(AgentThreadStatus(name: status.name) == status)
        }
        #expect(AgentThreadStatus.unknown.name == "offline")
    }

    @Test func messagesJoinTheirTextAndKeepToolRuns() {
        let message = TranscriptMessage(
            id: "m", role: .assistant,
            blocks: [.text("Looking.", id: "1"), .tools(count: 2, id: "2"), .text("Done.", id: "3")]
        )
        let json = MessageJSON(message)
        #expect(json.text == "Looking.\n\nDone.")
        #expect(json.blocks.map(\.type) == ["text", "tools", "text"])
        #expect(json.blocks[1].toolCalls == 2)
    }

    @Test func errorsMapToDocumentedExitCodes() {
        #expect(CLIError(.unreachable, "").exitCode == 4)
        #expect(CLIError(.outcomeUnknown, "").exitCode == 5)
        #expect(CLIError(.revoked, "").exitCode == 3)
        #expect(CLIError(.timeout, "").exitCode == 6)
    }
}
