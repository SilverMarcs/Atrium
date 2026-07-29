import ACP
import Foundation
import Testing
@testable import Atrium

@Suite("Codex ACP integration")
struct CodexACPIntegrationTests {
    @Test(
        "Completes an authenticated prompt through Atrium",
        .enabled(if: integrationTestEnabled)
    )
    func promptRoundTrip() async throws {
        let session = ACPSession()
        session.provider = .codex
        session.permissionMode = .standard
        session.setWorkingDirectory(FileManager.default.currentDirectoryPath)

        var responseText = ""
        session.onSessionUpdate = { update in
            guard case .agentMessageChunk(let content) = update,
                  case .text(let text) = content else {
                return
            }
            responseText += text.text
        }

        await session.launchAndCreateSession()
        #expect(session.error == nil)
        guard session.isConnected else { return }

        session.send(content: [
            .text(TextContent(text: "Reply with exactly ATRIUM_CODEX_OK and do not use tools."))
        ])

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(120))
        while session.isProcessing, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }

        #expect(session.error == nil)
        #expect(responseText.contains("ATRIUM_CODEX_OK"))

        session.disconnect()
        try await Task.sleep(for: .milliseconds(500))
    }

    nonisolated private static var integrationTestEnabled: Bool {
        ProcessInfo.processInfo.environment["ATRIUM_RUN_CODEX_INTEGRATION"] == "1"
            || FileManager.default.fileExists(atPath: "/tmp/atrium-run-codex-integration")
    }
}
