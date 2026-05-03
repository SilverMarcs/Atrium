import Foundation

enum CommandState: Equatable {
    case idle
    case running
    case finished(exitCode: Int32)

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}
