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
    case start(id: UUID, taskID: String, source: LivePreviewSource)
    case answer(id: UUID, sdp: String)
    case stop(id: UUID)
}

nonisolated struct PreviewICEServer: Codable, Sendable {
    let urls: [String]
    let username: String?
    let credential: String?

    static let stun = Self(urls: ["stun:stun.cloudflare.com:3478"], username: nil, credential: nil)
}
