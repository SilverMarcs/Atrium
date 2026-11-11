#if !canImport(Network)
import Foundation
import NIOCore
import NIOHTTP1

/// Environment proxy selection never resolves the destination hostname.
nonisolated struct HTTPProxy {
    let host: String
    let port: Int
    let authorization: String?

    static func select(for url: URL, environment: [String: String]) throws -> HTTPProxy? {
        guard url.scheme == "wss", let host = url.host() else { return nil }
        let port = url.port ?? 443
        let exclusions = value("no_proxy", "NO_PROXY", in: environment) ?? ""
        if exclusions.split(separator: ",").contains(where: { bypasses(host: host, port: port, entry: String($0)) }) {
            return nil
        }
        guard let address = value("https_proxy", "HTTPS_PROXY", in: environment) else { return nil }
        guard let components = URLComponents(string: address), components.scheme != nil else {
            throw HTTPProxyError.invalidURL
        }
        guard components.scheme?.lowercased() == "http" else { throw HTTPProxyError.unsupportedScheme }
        let proxyPort = components.port ?? 80
        guard let proxyHost = components.host, !proxyHost.isEmpty,
              (1...65535).contains(proxyPort),
              components.path.isEmpty || components.path == "/",
              components.query == nil, components.fragment == nil else {
            throw HTTPProxyError.invalidURL
        }
        let authorization = components.user.map {
            "Basic " + Data("\($0):\(components.password ?? "")".utf8).base64EncodedString()
        }
        return HTTPProxy(host: unbracketed(proxyHost), port: proxyPort, authorization: authorization)
    }

    private static func value(_ lower: String, _ upper: String, in environment: [String: String]) -> String? {
        [lower, upper].compactMap { environment[$0]?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    private static func unbracketed(_ host: String) -> String {
        host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    }

    private static func bypasses(host: String, port: Int, entry: String) -> Bool {
        let entry = entry.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if entry == "*" { return true }
        guard !entry.isEmpty,
              let pattern = URLComponents(string: "http://" + entry),
              let patternHost = pattern.host, pattern.path.isEmpty,
              pattern.user == nil, pattern.password == nil, pattern.query == nil, pattern.fragment == nil,
              pattern.port == nil || pattern.port == port else { return false }
        let hostname = unbracketed(host).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let domain = unbracketed(patternHost).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return !domain.isEmpty && (hostname == domain || hostname.hasSuffix("." + domain))
    }
}

/// Only the CONNECT request passes through these temporary HTTP handlers.
/// Relay headers and the existing TLS/WebSocket pipeline are added afterwards.
nonisolated final class HTTPProxyConnectHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPClientResponsePart
    typealias OutboundOut = HTTPClientRequestPart

    private let authority: String
    private let authorization: String?
    private let established: EventLoopPromise<Void>
    private var timeout: Scheduled<Void>?
    private var accepted = false
    private var completed = false

    private init(authority: String, authorization: String?, established: EventLoopPromise<Void>) {
        self.authority = authority
        self.authorization = authorization
        self.established = established
    }

    static func install(on channel: any Channel, proxy: HTTPProxy, host: String, port: Int) throws -> EventLoopFuture<Void> {
        let established = channel.eventLoop.makePromise(of: Void.self)
        let authority = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]:\(port)" : "\(host):\(port)"
        let handler = HTTPProxyConnectHandler(authority: authority, authorization: proxy.authorization, established: established)
        try channel.pipeline.syncOperations.addHandler(HTTPRequestEncoder(), name: "proxy.encoder")
        try channel.pipeline.syncOperations.addHandler(ByteToMessageHandler(HTTPResponseDecoder()), name: "proxy.decoder")
        try channel.pipeline.syncOperations.addHandler(handler, name: "proxy.connect")
        established.futureResult.whenFailure { _ in channel.close(promise: nil) }
        return established.futureResult
    }

    func channelActive(context: ChannelHandlerContext) {
        var headers = HTTPHeaders([("Host", authority)])
        if let authorization { headers.add(name: "Proxy-Authorization", value: authorization) }
        let head = HTTPRequestHead(version: .http1_1, method: .CONNECT, uri: authority, headers: headers)
        context.write(Self.wrapOutboundOut(.head(head)), promise: nil)
        let written = context.eventLoop.makePromise(of: Void.self)
        let bound = NIOLoopBound(self, eventLoop: context.eventLoop)
        written.futureResult.whenFailure { _ in bound.value.fail(.connectionFailed) }
        context.writeAndFlush(Self.wrapOutboundOut(.end(nil)), promise: written)
        timeout = context.eventLoop.scheduleTask(in: .seconds(10)) {
            bound.value.fail(.timedOut)
        }
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !completed else { return }
        switch Self.unwrapInboundIn(data) {
        case .head(let response):
            if (200..<300).contains(response.status.code) {
                accepted = true
            } else if response.status.code >= 200 || response.status.code == 101 {
                fail(HTTPProxyError.rejected(response.status.code))
            }
        case .end where accepted:
            completed = true
            timeout?.cancel()
            let pipeline = context.pipeline
            pipeline.removeHandler(name: "proxy.encoder")
                .flatMap { pipeline.removeHandler(name: "proxy.connect") }
                .flatMap { pipeline.removeHandler(name: "proxy.decoder") }
                .cascade(to: established)
        default:
            break
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        fail(HTTPProxyError.connectionFailed)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        // Never include proxy response text, URLs, or credentials in errors.
        fail(HTTPProxyError.connectionFailed)
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        fail(.connectionFailed)
    }

    private func fail(_ error: HTTPProxyError) {
        guard !completed else { return }
        completed = true
        timeout?.cancel()
        established.fail(error)
    }
}

nonisolated enum HTTPProxyError: LocalizedError {
    case invalidURL
    case unsupportedScheme
    case rejected(UInt)
    case connectionFailed
    case timedOut

    var errorDescription: String? {
        switch self {
        case .invalidURL: "The HTTP proxy URL is invalid."
        case .unsupportedScheme: "Only http:// proxy URLs are supported for secure WebSocket connections."
        case .rejected(let status): "The HTTP proxy rejected CONNECT (HTTP \(status))."
        case .connectionFailed: "The HTTP proxy connection failed."
        case .timedOut: "The HTTP proxy CONNECT request timed out."
        }
    }
}
#endif
