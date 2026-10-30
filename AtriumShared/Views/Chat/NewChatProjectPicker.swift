import AtriumClient
import AtriumProtocol
import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Shows the project's custom icon, falling back to its type logo or a folder.
struct NewChatProjectPicker: View {
    @State private var customIcons: [String: Image] = [:]
    let hosts: HostDirectory
    let host: HostClient
    let draft: TaskDraft

    private var workspaces: [WireWorkspace] { host.tasks?.workspaces ?? [] }
    private var selectedWorkspace: WireWorkspace? { workspaces.first { $0.id == draft.workspaceID } }
    private var projectName: String { selectedWorkspace?.name ?? "Choose Project" }

    var body: some View {
        Menu {
            Picker("Project", selection: Binding(
                get: { draft.workspaceID },
                set: { hosts.openNewChat(in: WorkspaceRef(hostID: host.id, workspaceID: $0)) }
            )) {
                ForEach(workspaces) { workspace in
                    if workspace.projectType == "none" {
                        Text(workspace.name)
                            .tag(workspace.id)
                    } else {
                        Label {
                            Text(workspace.name)
                        } icon: {
                            menuIcon(for: workspace)
                        }
                        .tag(workspace.id)
                    }
                }
            }
            .pickerStyle(.inline)
            .labelStyle(.titleAndIcon)
            .labelsHidden()
        } label: {
            NewChatPickerLabel(title: projectName) {
                if let workspace = selectedWorkspace, workspace.projectType != "none" {
                    menuIcon(for: workspace)
                        .resizable()
                        .scaledToFit()
                } else {
                    Image(systemName: "folder")
                }
            }
        }
        .menuOrder(.fixed)
        .accessibilityLabel("Project")
        .accessibilityValue(projectName)
        .task(id: [host.id] + workspaces.compactMap(\.customIconKey)) {
            await loadCustomIcons()
        }
    }

    private func loadCustomIcons() async {
        customIcons = [:]
        for key in workspaces.compactMap(\.customIconKey) {
            guard !Task.isCancelled else { return }
            guard let data = await host.icon(forKey: key) else { continue }
            guard !Task.isCancelled else { return }
            #if os(iOS)
            guard let image = UIImage(data: data),
                  let thumbnail = image.preparingThumbnail(of: CGSize(width: 18, height: 18)) else { continue }
            customIcons[key] = Image(uiImage: thumbnail)
            #else
            guard let image = NSImage(data: data) else { continue }
            let longestSide = max(image.size.width, image.size.height)
            if longestSide > 0 {
                let scale = 18 / longestSide
                image.size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            }
            customIcons[key] = Image(nsImage: image)
            #endif
        }
    }

    /// Pass native images directly to the menu so bundled logos need no loading task.
    private func menuIcon(for workspace: WireWorkspace) -> Image {
        if let key = workspace.customIconKey, let icon = customIcons[key] { return icon }
        if let name = workspace.projectIcon { return Image(name) }
        return Image(systemName: "folder")
    }
}
