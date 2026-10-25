import SwiftUI

struct ThreadWorkspaceIcon: View {
    let workspace: Workspace?
    @ScaledMetric(relativeTo: .subheadline) private var iconSize = 11
    @State private var customImage: NSImage?

    var body: some View {
        if workspace?.projectType != ProjectType.none {
            ProjectIconImage(
                customImage: customImage.map { Image(nsImage: $0) },
                typeIconName: workspace.flatMap { $0.projectType == .unknown ? nil : $0.projectType.iconName }
            )
            .frame(width: iconSize, height: iconSize)
            .task(id: workspace?.customIconURL) {
                customImage = nil
                guard let url = workspace?.customIconURL else { return }
                let image = await ImageLoader.decode(at: url)
                guard !Task.isCancelled else { return }
                customImage = image
            }
        }
    }
}
