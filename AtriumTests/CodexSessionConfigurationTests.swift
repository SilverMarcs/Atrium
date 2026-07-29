import Testing
@testable import Atrium

@Suite("Codex session configuration")
struct CodexSessionConfigurationTests {
    @Test("Maps Atrium permissions to current Codex agent modes")
    func agentModes() {
        #expect(CodexSessionConfiguration.agentMode(for: .standard) == "agent")
        #expect(CodexSessionConfiguration.agentMode(for: .acceptEdits) == "agent")
        #expect(CodexSessionConfiguration.agentMode(for: .plan) == "read-only")
        #expect(CodexSessionConfiguration.agentMode(for: .bypassPermissions) == "agent-full-access")
    }

    @Test("Plan mode controls Codex collaboration mode independently")
    func collaborationModes() {
        #expect(CodexSessionConfiguration.collaborationMode(for: .standard) == "default")
        #expect(CodexSessionConfiguration.collaborationMode(for: .plan) == "plan")
        #expect(CodexSessionConfiguration.collaborationMode(for: .bypassPermissions) == "default")
    }

    @Test("Migrates bracketed legacy model IDs")
    func bracketedModelMigration() {
        let available = ["gpt-5.6-sol", "gpt-5.6-terra"]

        #expect(
            CodexSessionConfiguration.compatibleModelSelection(
                "gpt-5.6-sol[high]",
                availableValues: available
            ) == "gpt-5.6-sol"
        )
    }

    @Test("Migrates slash-delimited legacy model IDs")
    func slashModelMigration() {
        let available = ["gpt-5.6-sol", "gpt-5.6-terra"]

        #expect(
            CodexSessionConfiguration.compatibleModelSelection(
                "gpt-5.6-terra/xhigh",
                availableValues: available
            ) == "gpt-5.6-terra"
        )
    }

    @Test("Rejects stale models that the adapter cannot select")
    func unavailableModelMigration() {
        #expect(
            CodexSessionConfiguration.compatibleModelSelection(
                "retired-codex-model[medium]",
                availableValues: ["gpt-5.6-sol"]
            ) == nil
        )
    }
}
