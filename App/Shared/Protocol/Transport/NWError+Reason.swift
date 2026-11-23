import Network

extension NWError {
    /// Why a connection failed or dropped, short enough to show under a
    /// host's name, rather than the underlying POSIX, DNS or TLS error.
    var connectionReason: String {
        switch self {
        case .posix(.ENETDOWN), .posix(.ENETUNREACH), .dns: "No network connection"
        default: "Can’t connect"
        }
    }
}
