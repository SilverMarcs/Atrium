import SwiftUI
import UniformTypeIdentifiers

/// A host's projects, to rename, reorder and tidy up. Adding and removing
/// projects, and choosing their icons from files, stay with the host itself.
struct ProjectsSheet: View {
    let hosts: HostDirectory
    @Environment(\.dismiss) private var dismiss
    @State private var hostID: String?
    @State private var renaming: WireWorkspace?
    @State private var name = ""
    @State private var iconWorkspace: WireWorkspace?
    @State private var showingIconImporter = false
    @State private var showingFolderImporter = false

    private var host: HostClient? { hosts.host(hostID) }
    private var connectedHosts: [HostClient] { hosts.hosts.filter(\.isConnected) }

    var body: some View {
        let workspaces = host?.tasks?.workspaces ?? []
        NavigationStack {
            List {
                if let host {
                    ForEach(workspaces) { workspace in
                        ProjectRow(workspace: workspace, host: host)
                            .contextMenu {
                                ProjectMenu(workspace: workspace, host: host) {
                                    name = workspace.name
                                    renaming = workspace
                                } chooseIcon: {
                                    iconWorkspace = workspace
                                    showingIconImporter = true
                                }
                            }
                    }
                    .onMove { source, destination in
                        guard let index = source.first else { return }
                        let target = destination > index ? destination - 1 : destination
                        withAnimation { send(.move(toIndex: target), to: workspaces[index]) }
                    }
                }
            }
            // Projects changed on the host slide into place.
            .animation(.default, value: workspaces.map(\.id))
            .overlay {
                if let host, workspaces.isEmpty {
                    ContentUnavailableView(
                        "No Projects",
                        systemImage: "folder",
                        description: Text(host.isLocal ? "Add a folder to start tasks in it." : "Add projects in Atrium on \(host.name).")
                    )
                }
            }
            .fileImporter(isPresented: $showingIconImporter, allowedContentTypes: [.png, .jpeg, .icns]) { result in
                defer { iconWorkspace = nil }
                guard let workspace = iconWorkspace, case .success(let url) = result else { return }
                send(.setIcon(path: url.path(percentEncoded: false)), to: workspace)
            }
            .navigationTitle("Projects")
            #if os(iOS)
            // The title menu switches hosts, as it filters them in the task list.
            .navigationSubtitle(host?.name ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarTitleMenu {
                ProjectsHostPicker(hosts: connectedHosts, selection: $hostID)
            }
            #endif
            .toolbar {
                #if os(iOS)
                ToolbarItem(placement: .cancellationAction) {
                    EditButton()
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", role: .confirm) { dismiss() }
                }
                #else
                // Mac sheets keep their controls in the bottom bar.
                if connectedHosts.count > 1 {
                    ToolbarItem {
                        ProjectsHostPicker(hosts: connectedHosts, selection: $hostID)
                            .labelsHidden()
                            .fixedSize()
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", role: .close) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
                #endif
                if host?.isLocal == true {
                    ToolbarItem {
                        Button("Add Folder…", systemImage: "folder.badge.plus") { showingFolderImporter = true }
                    }
                }
            }
        }
        #if os(macOS)
        .frame(width: 420, height: 460)
        #endif
        .fileImporter(isPresented: $showingFolderImporter, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { host?.send(.addWorkspace(path: url.path(percentEncoded: false))) }
        }
        .alert("Rename Project", isPresented: Binding(
            get: { renaming != nil },
            set: { if !$0 { renaming = nil } }
        ), presenting: renaming) { workspace in
            TextField("Name", text: $name)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { send(.rename(name), to: workspace) }
        } message: { _ in
            Text("Leave it empty to use the folder’s name.")
        }
        .alert("Couldn’t Update Project", isPresented: Binding(
            get: { hosts.actionError != nil },
            set: { if !$0 { hosts.actionError = nil } }
        )) {
            Button("OK") { hosts.actionError = nil }
        } message: {
            Text(hosts.actionError ?? "")
        }
        .onAppear {
            hostID = hosts.visibleTask?.hostID ?? hosts.visibleHosts.first(where: \.isConnected)?.id
        }
    }

    private func send(_ action: WorkspaceAction, to workspace: WireWorkspace) {
        host?.send(.workspace(id: workspace.id, action: action))
    }
}

/// The host whose projects the sheet lists.
private struct ProjectsHostPicker: View {
    let hosts: [HostClient]
    @Binding var selection: String?

    var body: some View {
        Picker("Host", selection: $selection) {
            ForEach(hosts) { host in
                Text(host.name).tag(Optional(host.id))
            }
        }
    }
}

/// What can be changed about a project from another device, and on its own
/// host, its icon file and whether it's listed at all.
private struct ProjectMenu: View {
    let workspace: WireWorkspace
    let host: HostClient
    let rename: () -> Void
    let chooseIcon: () -> Void

    var body: some View {
        Button("Rename…", systemImage: "pencil", action: rename)

        Menu {
            Picker("Project Type", selection: Binding(
                get: { ProjectType(rawValue: workspace.projectType) ?? .unknown },
                set: { send(.setProjectType($0.rawValue)) }
            )) {
                ForEach(ProjectType.allCases, id: \.self) { type in
                    Label {
                        Text(type.displayName)
                    } icon: {
                        if !type.iconName.isEmpty {
                            Image(type.iconName)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 18, height: 18)
                        }
                    }
                    .tag(type)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()

            Divider()

            Button("Auto-Detect") { send(.detectProjectType) }
        } label: {
            Label("Project Type", systemImage: "shippingbox")
        }

        if host.isLocal {
            Button("Choose Icon…", systemImage: "photo", action: chooseIcon)
        }

        if workspace.customIconKey != nil {
            Button("Reset Icon", systemImage: "arrow.uturn.backward") { send(.clearIcon) }
        }

        if host.isLocal {
            Divider()
            Button("Delete", systemImage: "trash", role: .destructive) { send(.remove) }
        }
    }

    private func send(_ action: WorkspaceAction) {
        host.send(.workspace(id: workspace.id, action: action))
    }
}
