import Foundation
import MCP
import OSLog

nonisolated extension CallTool.Result {
    static func text(_ text: String, isError: Bool = false) -> Self {
        Self(content: [.text(text: text, annotations: nil, _meta: nil)], isError: isError ? true : nil)
    }
}

/// A call a tool turned down, reported to the model as a failed result it can act on.
nonisolated struct ToolError: Error {
    let message: String

    init(_ message: String) {
        self.message = message
    }
}

/// Atrium's MCP server, for ChatGPT, which reaches it through OpenAI's
/// tunnel client and is served statelessly over the bridge.
///
/// Each request is authenticated by ChatGPT's bearer token alone, and a
/// fresh SDK server answers it.
@MainActor
final class AtriumToolServer {
    nonisolated static let name = "atrium"

    private static let log = Logger(subsystem: "Atrium", category: "Tools")
    private let credential: ChatGPTCredential
    private let orchestration: OrchestrationTools

    init(credential: ChatGPTCredential, tools: OrchestrationTools) {
        self.credential = credential
        self.orchestration = tools
    }

    func respond(to request: BridgeRequest) async -> BridgeResponse {
        // Browsers send an Origin; the tunnel client doesn't. A page can't
        // read the token, but refuse it outright anyway.
        if let origin = request.headers["origin"], !Self.isLoopback(origin) {
            return BridgeResponse(status: 403)
        }
        guard credential.accepts(request.headers["authorization"]) else {
            return BridgeResponse(status: 401, headers: ["WWW-Authenticate": "Bearer"])
        }
        let server = Server(
            name: Self.name, version: "2.0", title: "Atrium",
            instructions: OrchestrationTools.instructions,
            capabilities: .init(tools: .init(listChanged: false))
        )
        let tools = OrchestrationTools.tools
        await server.withMethodHandler(ListTools.self) { _ in ListTools.Result(tools: tools) }
        let authorization = request.headers["authorization"]
        await server.withMethodHandler(CallTool.self) { [weak self] params in
            guard let self else { return .text("Atrium has stopped.", isError: true) }
            return await self.call(params.name, arguments: params.arguments ?? [:], authorization: authorization)
        }
        let transport = StatelessHTTPServerTransport(validationPipeline: StandardValidationPipeline(validators: [
            AcceptHeaderValidator(mode: .jsonOnly),
            ContentTypeValidator(),
            ProtocolVersionValidator(),
        ]))
        do {
            try await server.start(transport: transport)
        } catch {
            return BridgeResponse(status: 500)
        }
        let response = await transport.handleRequest(HTTPRequest(
            method: request.method, headers: request.headers, body: Self.decodableBody(request.body), path: request.path
        ))
        await server.stop()
        let method = (try? JSONSerialization.jsonObject(with: request.body) as? [String: Any])?["method"] as? String ?? request.method
        Self.log.debug("ChatGPT \(method, privacy: .public) → \(response.statusCode)")
        return BridgeResponse(status: response.statusCode, headers: response.headers, body: response.bodyData ?? Data())
    }

    private func call(_ name: String, arguments: [String: Value], authorization: String?) async -> CallTool.Result {
        // The token may have been reset since the request arrived.
        guard credential.accepts(authorization) else { return .text("Atrium no longer accepts this credential.", isError: true) }
        do {
            return try await orchestration.call(name, arguments: arguments)
        } catch let error as ToolError {
            return .text(error.message, isError: true)
        } catch {
            return .text(error.localizedDescription, isError: true)
        }
    }

    /// The SDK reads a client's experimental capabilities as strings only, so
    /// ChatGPT's object-valued ones fail its `initialize` (swift-sdk issue #262).
    /// Atrium uses none of them, so they're dropped before the SDK sees them.
    private static func decodableBody(_ body: Data) -> Data {
        guard var message = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              message["method"] as? String == "initialize",
              var params = message["params"] as? [String: Any],
              var capabilities = params["capabilities"] as? [String: Any],
              let experimental = capabilities["experimental"] as? [String: Any],
              !experimental.values.allSatisfy({ $0 is String }) else { return body }
        capabilities["experimental"] = nil
        params["capabilities"] = capabilities
        message["params"] = params
        return (try? JSONSerialization.data(withJSONObject: message)) ?? body
    }

    private static func isLoopback(_ origin: String) -> Bool {
        guard let host = URL(string: origin)?.host() else { return false }
        return ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host)
    }
}
