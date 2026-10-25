import Foundation

enum CompanionConnectionState: Equatable {
    case idle
    case connecting(hostName: String)
    case connected(hostName: String)
    case failed(String)
}
