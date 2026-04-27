import Foundation
import ACP
import ACPModel

@Observable
final class ACPSessionDelegate: ClientDelegate, @unchecked Sendable {

    var pendingPermission: PermissionPrompt?

    @ObservationIgnored
    var onPermissionRequest: ((PermissionPrompt) -> Void)?

    // MARK: - Permissions

    func handlePermissionRequest(request: RequestPermissionRequest) async throws -> RequestPermissionResponse {
        let prompt = PermissionPrompt(
            toolName: request.toolCall.title ?? "Tool",
            options: request.options
        )

        await MainActor.run {
            self.pendingPermission = prompt
            self.onPermissionRequest?(prompt)
        }

        let optionId = await prompt.waitForResponse()

        await MainActor.run {
            self.pendingPermission = nil
        }

        if let optionId {
            return RequestPermissionResponse(outcome: PermissionOutcome(optionId: optionId))
        } else {
            return RequestPermissionResponse(outcome: PermissionOutcome(cancelled: true))
        }
    }

    // MARK: - File System

    func handleFileReadRequest(_ path: String, sessionId: String, line: Int?, limit: Int?) async throws -> ReadTextFileResponse {
        throw ACPDelegateError.notSupported
    }

    func handleFileWriteRequest(_ path: String, content: String, sessionId: String) async throws -> WriteTextFileResponse {
        throw ACPDelegateError.notSupported
    }

    // MARK: - Terminal

    func handleTerminalCreate(command: String, sessionId: String, args: [String]?, cwd: String?, env: [EnvVariable]?, outputByteLimit: Int?) async throws -> CreateTerminalResponse {
        throw ACPDelegateError.notSupported
    }

    func handleTerminalOutput(terminalId: TerminalId, sessionId: String) async throws -> TerminalOutputResponse {
        throw ACPDelegateError.notSupported
    }

    func handleTerminalWaitForExit(terminalId: TerminalId, sessionId: String) async throws -> WaitForExitResponse {
        throw ACPDelegateError.notSupported
    }

    func handleTerminalKill(terminalId: TerminalId, sessionId: String) async throws -> KillTerminalResponse {
        throw ACPDelegateError.notSupported
    }

    func handleTerminalRelease(terminalId: TerminalId, sessionId: String) async throws -> ReleaseTerminalResponse {
        throw ACPDelegateError.notSupported
    }
}

@Observable
final class PermissionPrompt: Identifiable {
    let id = UUID()
    let toolName: String
    let options: [PermissionOption]
    private var continuation: CheckedContinuation<String?, Never>?

    init(toolName: String, options: [PermissionOption]) {
        self.toolName = toolName
        self.options = options
    }

    func waitForResponse() async -> String? {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func respond(optionId: String?) {
        continuation?.resume(returning: optionId)
        continuation = nil
    }
}

enum ACPDelegateError: Error {
    case notSupported
}
