import SwiftUI

/// A project's icon: its custom image, else its project type's logo, else a folder.
/// Callers size it; each app loads custom images its own way.
struct ProjectIconImage: View {
    let customImage: Image?
    /// Asset name of the project type's logo.
    let typeIconName: String?
    var customImageCornerRadius: CGFloat = 0

    var body: some View {
        if let customImage {
            customImage
                .resizable()
                .scaledToFit()
                .clipShape(.rect(cornerRadius: customImageCornerRadius))
        } else if let typeIconName {
            Image(typeIconName)
                .resizable()
                .scaledToFit()
        } else {
            Image(systemName: "folder")
                .resizable()
                .scaledToFit()
                .foregroundStyle(.secondary)
        }
    }
}
