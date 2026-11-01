import Foundation
#if canImport(OSLog)
import OSLog
#endif

/// Connection milestones, for working out why a client can't reach a host.
public enum ClientLog {
    /// Also receives every message, as the command-line client's `--verbose` does.
    public static var handler: ((String) -> Void)?

    #if canImport(OSLog)
    private static let logger = Logger(subsystem: "com.SilverMarcs.Atrium", category: "HostClient")
    #endif

    static func info(_ message: String) {
        #if canImport(OSLog)
        logger.info("\(message, privacy: .public)")
        #endif
        handler?(message)
    }
}
