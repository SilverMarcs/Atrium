import SwiftUI

struct ThreadWorkspaceIcon: View {
    let workspace: Workspace?
    @ScaledMetric(relativeTo: .subheadline) private var iconSize = 11
    @State private var customImage: NSImage?

    var body: some View {
        if workspace?.projectType != ProjectType.none {
            Group {
                if let customImage {
                    Image(nsImage: customImage)
                        .resizable()
                        .scaledToFit()
                } else if let workspace, workspace.projectType != .unknown {
                    Image(workspace.projectType.iconName)
                        .resizable()
                        .scaledToFit()
                } else {
                    Image(systemName: "folder")
                        .resizable()
                        .scaledToFit()
                }
            }
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
