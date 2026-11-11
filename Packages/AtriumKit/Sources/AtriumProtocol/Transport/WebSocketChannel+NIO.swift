#if !canImport(Network)
import Foundation
import NIOCore
import NIOFoundationCompat
import NIOHTTP1
import NIOPosix
import NIOSSL
import NIOWebSocket

/// A `HostChannel` over a WebSocket on SwiftNIO, for platforms without the
/// Network framework. It dials a `ws://` or `wss://` URL, as the relay is
/// reached; messages arrive on the main actor in the order they were received.
@MainActor
public final class WebSocketChannel: HostChannel {
    public var onReady: (() -> Void)?
    public var onMessage: ((Data) -> Void)?
    public var onClose: ((String?) -> Void)?

    private let url: URL
    private let headers: [(name: String, value: String)]
    private var channel: (any Channel)?
    private var events: AsyncStream<SocketEvent>.Continuation?
    private var task: Task<Void, Never>?
    private var isClosed = false

    /// Dials `url`, sending `headers` with the WebSocket handshake.
    public init(url: URL, headers: [(name: String, value: String)] = []) {
        self.url = url
        self.headers = headers
    }

    public func start() {
        let (stream, events) = AsyncStream.makeStream(of: SocketEvent.self)
        self.events = events
        let url = url
        let headers = headers.map { ($0.name, $0.value) }
        task = Task { [weak self] in
            let channel: any Channel
            do {
                channel = try await Self.connect(to: url, headers: headers, events: events)
            } catch {
                self?.finish(Self.describe(error))
                return
            }
            guard let self, !self.isClosed else {
                channel.close(promise: nil)
                return
            }
            self.channel = channel
            self.onReady?()
            for await event in stream where !self.isClosed {
                switch event {
                case .message(let data): self.onMessage?(data)
                case .closed(let reason): self.finish(reason)
                }
            }
        }
    }

    public func send(_ data: Data) {
        send(ByteBuffer(data: data), opcode: .binary)
    }

    /// Sends a text message, such as a keep-alive the far end matches as text.
    public func send(text: String) {
        send(ByteBuffer(string: text), opcode: .text)
    }

    private func send(_ buffer: ByteBuffer, opcode: WebSocketOpcode) {
        guard !isClosed, let channel else { return }
        let frame = WebSocketFrame(fin: true, opcode: opcode, maskKey: .random(), data: buffer)
        let events = events
        channel.writeAndFlush(frame).whenFailure { error in
            events?.yield(.closed(Self.describe(error)))
        }
    }

    public func close() {
        finish(nil)
    }

    private func finish(_ reason: String?) {
        guard !isClosed else { return }
        isClosed = true
        events?.finish()
        task?.cancel()
        if let channel {
            var code = ByteBuffer()
            code.write(webSocketErrorCode: .normalClosure)
            let frame = WebSocketFrame(fin: true, opcode: .connectionClose, maskKey: .random(), data: code)
            channel.writeAndFlush(frame).whenComplete { _ in channel.close(promise: nil) }
        }
        channel = nil
        let onClose = onClose
        onReady = nil
        onMessage = nil
        self.onClose = nil
        onClose?(reason)
    }

    private nonisolated static func describe(_ error: any Error) -> String {
        if let error = error as? HTTPProxyError { return error.localizedDescription }
        if let error = error as? ChannelError, case .connectTimeout = error {
            return "The connection timed out."
        }
        return "Couldn’t connect: \(error)"
    }

    /// Opens the TCP connection, adds TLS for `wss`, and upgrades it to a
    /// WebSocket whose frames are handed to `events`.
    @concurrent
    private nonisolated static func connect(
        to url: URL, headers: [(String, String)], events: AsyncStream<SocketEvent>.Continuation
    ) async throws -> any Channel {
        guard let host = url.host(), let scheme = url.scheme, scheme == "ws" || scheme == "wss" else {
            throw WebSocketUpgradeError.invalidURL
        }
        let isSecure = scheme == "wss"
        let port = url.port ?? (isSecure ? 443 : 80)
        let proxy = try HTTPProxy.select(for: url, environment: ProcessInfo.processInfo.environment)
        let tls = isSecure ? try NIOSSLContext(configuration: .makeClientConfiguration()) : nil
        var path = url.path(percentEncoded: true)
        if path.isEmpty { path = "/" }
        if let query = url.query(percentEncoded: true) { path += "?\(query)" }
        var requestHeaders = HTTPHeaders(headers)
        requestHeaders.replaceOrAdd(name: "Host", value: url.port.map { "\(host):\($0)" } ?? host)
        let head = HTTPRequestHead(version: .http1_1, method: .GET, uri: path, headers: requestHeaders)

        let upgrade: EventLoopFuture<UpgradeResult> = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .connectTimeout(.seconds(10))
            .connect(host: proxy?.host ?? host, port: proxy?.port ?? port) { channel in
                channel.eventLoop.makeCompletedFuture {
                    let tunnel = try proxy.map {
                        try HTTPProxyConnectHandler.install(on: channel, proxy: $0, host: host, port: port)
                    } ?? channel.eventLoop.makeSucceededVoidFuture()
                    return tunnel.flatMap {
                        channel.eventLoop.makeCompletedFuture {
                            if let tls {
                                try channel.pipeline.syncOperations.addHandler(NIOSSLClientHandler(context: tls, serverHostname: host))
                            }
                            let upgrader = NIOTypedWebSocketClientUpgrader<UpgradeResult>(
                                maxFrameSize: HostProtocol.maxMessageBytes,
                                upgradePipelineHandler: { channel, _ in
                                    channel.eventLoop.makeCompletedFuture {
                                        try channel.pipeline.syncOperations.addHandler(NIOWebSocketFrameAggregator(
                                            minNonFinalFragmentSize: 0,
                                            maxAccumulatedFrameCount: .max,
                                            maxAccumulatedFrameSize: HostProtocol.maxMessageBytes
                                        ))
                                        try channel.pipeline.syncOperations.addHandler(FrameHandler(events: events))
                                        return UpgradeResult.upgraded(channel)
                                    }
                                }
                            )
                            let configuration = NIOTypedHTTPClientUpgradeConfiguration<UpgradeResult>(
                                upgradeRequestHead: head,
                                upgraders: [upgrader],
                                notUpgradingCompletionHandler: { channel in channel.eventLoop.makeSucceededFuture(.declined) }
                            )
                            return try channel.pipeline.syncOperations.configureUpgradableHTTPClientPipeline(
                                configuration: .init(upgradeConfiguration: configuration)
                            )
                        }.flatMap { $0 }
                    }
                }
            }
        switch try await upgrade.get() {
        case .upgraded(let channel): return channel
        case .declined: throw WebSocketUpgradeError.declined
        }
    }
}

private nonisolated enum SocketEvent: Sendable {
    case message(Data)
    case closed(String?)
}

private nonisolated enum UpgradeResult: Sendable {
    case upgraded(any Channel)
    case declined
}

/// Hands a WebSocket's messages to the channel and answers its pings.
private nonisolated final class FrameHandler: ChannelInboundHandler, Sendable {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame

    private let events: AsyncStream<SocketEvent>.Continuation

    init(events: AsyncStream<SocketEvent>.Continuation) {
        self.events = events
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = Self.unwrapInboundIn(data)
        switch frame.opcode {
        case .binary, .text:
            events.yield(.message(Data(buffer: frame.unmaskedData)))
        case .ping:
            let pong = WebSocketFrame(fin: true, opcode: .pong, maskKey: .random(), data: frame.unmaskedData)
            context.writeAndFlush(Self.wrapOutboundOut(pong), promise: nil)
        case .connectionClose:
            events.yield(.closed(nil))
            context.close(promise: nil)
        default:
            break
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        events.yield(.closed(nil))
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        events.yield(.closed("The connection failed: \(error)"))
        context.close(promise: nil)
    }
}

private nonisolated enum WebSocketUpgradeError: LocalizedError {
    case invalidURL
    case declined

    var errorDescription: String? {
        switch self {
        case .invalidURL: "The relay address isn’t a WebSocket URL."
        case .declined: "The relay didn’t accept the WebSocket connection."
        }
    }
}
#endif
