import SwiftUI

struct GitStatusBadge: View {
    let kind: GitChangeKind
    let staged: Bool

    var body: some View {
        Text(kind.statusSymbol)
            .font(.system(size: 9, weight: .medium, design: .rounded))
            .foregroundStyle(staged ? .white : kind.color)
            .frame(width: 16, height: 16)
            .contentShape(RoundedRectangle(cornerRadius: 3))
            .background {
                if staged {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(kind.color)
                } else {
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(kind.color, lineWidth: 1)
                }
            }
    }
}
