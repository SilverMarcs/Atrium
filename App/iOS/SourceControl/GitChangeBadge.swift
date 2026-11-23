import SwiftUI

struct GitChangeBadge: View {
    let kind: GitChangeKind
    @ScaledMetric(relativeTo: .body) private var size = 25

    var body: some View {
        Text(kind.statusSymbol)
            .font(.caption2.bold())
            .frame(width: size, height: size)
            .foregroundStyle(.white)
            .background(kind.color, in: .rect(cornerRadius: 4))
            .accessibilityLabel(kind.rawValue)
    }
}
