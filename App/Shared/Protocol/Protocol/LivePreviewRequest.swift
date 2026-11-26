import Foundation

nonisolated enum LivePreviewSource: String, Codable, CaseIterable, Identifiable, Sendable {
    case browser
    case simulator

    var id: Self { self }

    var title: String {
        switch self {
        case .browser: "Browser"
        case .simulator: "Simulator"
        }
    }

    var symbol: String {
        switch self {
        case .browser: "safari"
        case .simulator: "iphone"
        }
    }
}

nonisolated enum LivePreviewRequest: Codable, Sendable {
    case sources(taskID: String)
    case simulators(taskID: String)
    case start(id: UUID, taskID: String, source: LivePreviewSource, openBrowser: Bool? = nil, simulatorID: String? = nil)
    case answer(id: UUID, sdp: String)
    case stop(id: UUID)
    case input(id: UUID, LivePreviewInput)
}

nonisolated struct PreviewICEServer: Codable, Sendable {
    let urls: [String]
    let username: String?
    let credential: String?

    static let stun = Self(urls: ["stun:stun.cloudflare.com:3478"], username: nil, credential: nil)
}

nonisolated struct LivePreviewSimulator: Codable, Sendable, Identifiable, Hashable {
    let id: String
    let name: String
    let runtime: String
    let symbol: String
}

nonisolated enum LivePreviewInput: Codable, Sendable {
    static let maxTextBytes = 4096

    case tap(PreviewPoint)
    case swipe(from: PreviewPoint, to: PreviewPoint)
    case text(String)
    case key(PreviewKey)
    case openPage(String)
    case back
    case forward
    case reload
    case home
}

nonisolated struct PreviewPoint: Codable, Sendable {
    let x: Double
    let y: Double

    var isValid: Bool { (0...1).contains(x) && (0...1).contains(y) }
}

nonisolated enum PreviewKey: String, Codable, Sendable {
    case enter = "Enter"
    case backspace = "Backspace"
}
