#if canImport(Network)
import Network

public extension NWParameters {
    /// TCP, or TLS over it, between a host and a client or the relay. Either
    /// end can drop off its network without the connection closing, as when
    /// it joins another Wi-Fi network or sleeps, and TCP alone takes minutes to
    /// notice, or never while the connection is idle. Probing idle connections
    /// and giving up on unanswered data notice within about fifteen seconds.
    static func hostConnection(secure: Bool = false) -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 5
        tcp.keepaliveInterval = 5
        tcp.keepaliveCount = 2
        tcp.connectionDropTime = 15
        return NWParameters(tls: secure ? NWProtocolTLS.Options() : nil, tcp: tcp)
    }
}
#endif
