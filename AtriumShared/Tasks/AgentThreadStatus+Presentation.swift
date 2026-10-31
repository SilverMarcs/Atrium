import AtriumProtocol
import SwiftUI

extension AgentThreadStatus {
    /// A plain glyph for the status, without a circle or other shape around it.
    var systemImage: String {
        switch self {
        case .processing: "progress.indicator"
        case .waiting: "exclamationmark"
        case .done: "checkmark"
        case .idle: "minus"
        case .failed: "xmark"
        case .stopped: "stop.fill"
        case .unknown: "bolt.horizontal"
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
