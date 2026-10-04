import Foundation

enum ProcessOutput: Sendable {
    case stdout(Data), stderr(Data), exited(Int32)
}
