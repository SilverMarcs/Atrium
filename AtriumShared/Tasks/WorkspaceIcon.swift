import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// A project's icon, fetching its custom image from its host once.
struct WorkspaceIcon: View {
    let workspace: WireWorkspace?
    let host: HostClient
    @ScaledMetric private var size: CGFloat
    @State private var customImage: Image?

    init(_ workspace: WireWorkspace?, on host: HostClient, size: CGFloat = 22, relativeTo textStyle: Font.TextStyle = .body) {
        self.workspace = workspace
        self.host = host
        _size = ScaledMetric(wrappedValue: size, relativeTo: textStyle)
    }

    var body: some View {
        // A project can opt out of an icon altogether.
        if workspace?.projectType != "none" {
            ProjectIconImage(
                customImage: customImage,
                typeIconName: workspace?.projectIcon,
                customImageCornerRadius: size / 4
            )
            .frame(width: size, height: size)
            .task(id: workspace?.customIconKey) {
                customImage = nil
                guard let key = workspace?.customIconKey, let data = await host.icon(forKey: key) else { return }
                #if os(iOS)
                customImage = UIImage(data: data).map(Image.init(uiImage:))
                #else
                customImage = NSImage(data: data).map(Image.init(nsImage:))
                #endif
            }
        }
    }
}
