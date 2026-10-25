import SwiftUI

extension AgentThreadStatus {
    var systemImage: String {
        switch self {
        case .processing: "ellipsis.circle"
        case .waiting: "exclamationmark.bubble"
        case .done: "checkmark.circle"
        case .idle: "circle"
        case .failed: "xmark.octagon"
        case .stopped: "stop.circle"
        case .unknown: "bolt.horizontal.circle"
        }
    }

    var color: Color {
        switch self {
        case .processing: .accentColor
        case .waiting: .orange
        case .done: .green
        case .failed: .red
        case .idle, .stopped, .unknown: .secondary
        }
    }
}
