import SwiftUI

struct FileLabel<Trailing: View>: View {
    let name: String
    let icon: NSImage
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 4) {
            Label {
                Text(name)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } icon: {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 16, height: 16)
            }

            Spacer()

            trailing()
        }
    }
}

extension FileLabel where Trailing == EmptyView {
    init(name: String, icon: NSImage) {
        self.name = name
        self.icon = icon
        self.trailing = { EmptyView() }
    }
}
