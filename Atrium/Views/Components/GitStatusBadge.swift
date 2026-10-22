import SwiftUI

struct GitStatusBadge: View {
    let kind: GitChangeKind
    let staged: Bool

    private var color: Color {
        switch kind {
        case .modified, .typeChanged: .blue
        case .added, .untracked, .copied: .green
        case .deleted: .red
        case .renamed: .orange
        case .conflicted: .yellow
        }
    }

    var body: some View {
        Text(kind.statusSymbol)
            .font(.system(size: 9, weight: .medium, design: .rounded))
            .foregroundStyle(staged ? .white : color)
            .frame(width: 16, height: 16)
            .contentShape(RoundedRectangle(cornerRadius: 3))
            .background {
                if staged {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(color)
                } else {
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(color, lineWidth: 1)
                }
            }
    }
}
