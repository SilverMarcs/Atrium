import SwiftUI

extension GitChangeKind {
    var color: Color {
        switch self {
        case .modified, .typeChanged: .blue
        case .added, .untracked, .copied: .green
        case .deleted: .red
        case .renamed: .orange
        case .conflicted: .yellow
        }
    }
}
