import AtriumProtocol
import SwiftUI

extension AgentInteraction {
    /// What a pending request asks of the user.
    enum Kind {
        case approval, question, secret, terminal
    }

    var kind: Kind {
        if !supportsResponse { return .terminal }
        if questions.isEmpty { return .approval }
        return questions.allSatisfy(\.isSecret) ? .secret : .question
    }
}

extension AgentInteraction.Kind {
    var symbolName: String {
        switch self {
        case .approval: "hand.raised.fill"
        case .question: "questionmark.bubble.fill"
        case .secret: "key.fill"
        case .terminal: "apple.terminal.fill"
        }
    }

    var color: Color {
        switch self {
        case .approval, .terminal: .orange
        case .question: .indigo
        case .secret: .teal
        }
    }

    var waitingLabel: String {
        switch self {
        case .approval: "Needs approval"
        case .question: "Has a question"
        case .secret: "Needs a secret"
        case .terminal: "Continue in Terminal"
        }
    }
}
