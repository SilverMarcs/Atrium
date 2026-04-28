import SwiftUI

/// Three-line filter glyph used in toolbars to toggle archived items
/// in/out of the visible list. Tinted accent when filter is "active"
/// (i.e. archived rows are revealed).
struct ArchiveFilterButton: View {
    @Binding var showingArchived: Bool

    var body: some View {
        Button {
            withAnimation {
                showingArchived.toggle()
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease")
                .foregroundStyle(showingArchived ? .accent : .primary)
        }
    }
}
