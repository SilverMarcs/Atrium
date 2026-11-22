import SwiftUI

/// "+12 −4", leaving out a side with nothing.
struct LineCounts: View {
    let added: Int
    let removed: Int

    var body: some View {
        Self.text(added: added, removed: removed)
    }

    /// The counts as one text, which a menu's title keeps the colors of.
    static func text(added: Int, removed: Int) -> Text {
        var parts: [Text] = []
        if added > 0 || removed == 0 {
            parts.append(Text("+\(added)").foregroundStyle(.green))
        }
        if removed > 0 {
            parts.append(Text("−\(removed)").foregroundStyle(.red))
        }
        return parts.dropFirst().reduce(parts[0]) { Text("\($0) \($1)") }
    }
}
