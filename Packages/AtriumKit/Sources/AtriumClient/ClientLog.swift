import Foundation
import OSLog

/// Connection milestones, for working out why a client can't reach a host.
public enum ClientLog {
    private static let logger = Logger(subsystem: "com.SilverMarcs.Atrium", category: "HostClient")

    static func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
    }
}
