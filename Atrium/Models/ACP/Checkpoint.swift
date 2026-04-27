import Foundation

struct Checkpoint: Codable, Identifiable {
    var id = UUID()
    var turnIndex: Int = 0
    var createdAt: Date = Date()
    var repoSnapshots: [RepoSnapshot] = []

    init(turnIndex: Int) {
        self.turnIndex = turnIndex
    }
}

struct RepoSnapshot: Codable {
    let relativePath: String
    let isShadow: Bool
    let refName: String
}
