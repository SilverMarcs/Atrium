import SwiftUI
import UIKit

/// A project's icon, fetching its custom image from the host once.
struct WorkspaceIconView: View {
    @Environment(CompanionClient.self) private var client
    let workspace: WireWorkspace?
    @ScaledMetric private var size: CGFloat
    @State private var customImage: UIImage?

    init(workspace: WireWorkspace?, size: CGFloat = 22, relativeTo textStyle: Font.TextStyle = .body) {
        self.workspace = workspace
        _size = ScaledMetric(wrappedValue: size, relativeTo: textStyle)
    }

    var body: some View {
        ProjectIconImage(
            customImage: customImage.map { Image(uiImage: $0) },
            typeIconName: workspace?.projectIcon,
            customImageCornerRadius: size / 4
        )
        .frame(width: size, height: size)
        .task(id: workspace?.customIconKey) {
            customImage = nil
            guard let key = workspace?.customIconKey, let data = await client.icon(forKey: key) else { return }
            customImage = UIImage(data: data)
        }
    }
}
