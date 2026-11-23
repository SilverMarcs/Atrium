import AtriumProtocol
import Foundation

/// Connecting ChatGPT through the MCP gateway. ChatGPT's OAuth page opens
/// `atrium://agent?request=…` on the Mac; once the user approves, the host
/// pairs a device for it that can only use the host's tools, and hands that
/// device's token to the gateway, which returns where to send the browser so
/// ChatGPT finishes signing in. Removing the device in Settings → Remote
/// revokes it. The gateway holds that token sealed in ChatGPT's OAuth tokens
/// and speaks to the Mac as the device, so it sees ChatGPT's tool calls; the
/// access level the user picks bounds what they can do.
public enum AgentGateway {
    /// A request to connect, sealed by the gateway, which only it can read.
    public struct Request: Identifiable, Equatable {
        public let id = UUID()
        let sealed: String

        public init?(url: URL) {
            guard url.scheme == PairingLink.scheme, url.host == "agent",
                  let sealed = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "request" })?.value,
                  !sealed.isEmpty else { return nil }
            self.sealed = sealed
        }
    }

    struct Failure: LocalizedError {
        let errorDescription: String?
    }

    /// The gateway on the relay's own server.
    static var url: URL {
        var components = URLComponents(url: HostProtocol.relayURL, resolvingAgainstBaseURL: false)
        components?.scheme = HostProtocol.relayURL.scheme == "ws" ? "http" : "https"
        return components?.url ?? HostProtocol.relayURL
    }

    /// Pairs ChatGPT and returns where its sign-in continues in the browser.
    @MainActor
    public static func approve(_ request: Request, access: AgentAccess, on server: HostServer) async throws -> URL {
        let (device, token) = server.pairAgent(named: "ChatGPT", access: access)
        do {
            var call = URLRequest(url: url.appending(path: "oauth/approve"))
            call.httpMethod = "POST"
            call.setValue("application/json", forHTTPHeaderField: "Content-Type")
            call.httpBody = try JSONSerialization.data(withJSONObject: [
                "request": request.sealed,
                "grant": [
                    "hostID": HostIdentity.hostID, "publicKey": HostIdentity.publicKey.base64URLEncodedString(),
                    "deviceID": device.id.uuidString, "token": token,
                ],
            ])
            let (data, response) = try await URLSession.shared.data(for: call)
            let reply = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            guard (response as? HTTPURLResponse)?.statusCode == 200, let redirect = (reply?["redirect"] as? String).flatMap(URL.init(string:)) else {
                throw Failure(errorDescription: reply?["error_description"] as? String ?? "The connection couldn’t be completed. Connect again from ChatGPT.")
            }
            return redirect
        } catch {
            server.forgetDevice(device.id)
            throw error
        }
    }
}
