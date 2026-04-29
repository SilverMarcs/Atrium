import SwiftUI
import UIKit

/// Renders the icon for a workspace row: the user's custom icon if they
/// set one on the Mac side (shipped over the wire), otherwise a generic
/// folder symbol. Project-type icons aren't bundled in the iOS app on
/// purpose — keeps the binary lean.
struct WorkspaceIconView: View {
    let customIconData: Data?

    private static let iconSize: CGFloat = 32

    var body: some View {
        if let data = customIconData, let uiImage = UIImage(data: data) {
            Image(uiImage: uiImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: Self.iconSize, height: Self.iconSize)
                .clipShape(.rect(cornerRadius: 8))
        } else {
            Image(systemName: "folder")
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: Self.iconSize, height: Self.iconSize)
        }
    }
}
