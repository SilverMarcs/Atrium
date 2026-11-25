import SwiftUI
import UniformTypeIdentifiers

/// A project's folders, the primary one first: agents start in it and
/// commands run in it. On the project's own host they can be added,
/// reordered and removed; elsewhere they're only listed.
struct ProjectFoldersSheet: View {
    let host: HostClient
    let workspaceID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var showingFolderImporter = false

    private var folders: [String] { host.workspace(workspaceID)?.folders ?? [] }

    var body: some View {
        let folders = folders
        NavigationStack {
            List {
                Section {
                    ForEach(Array(folders.enumerated()), id: \.element) { index, folder in
                        FolderRow(path: folder, isPrimary: index == 0, canRemove: host.isLocal && folders.count > 1) {
                            send(folders.filter { $0 != folder })
                        }
                    }
                    .onMove(perform: host.isLocal ? { source, destination in
                        var reordered = folders
                        reordered.move(fromOffsets: source, toOffset: destination)
                        send(reordered)
                    } : nil)
                } footer: {
                    #if os(iOS)
                    note
                    #endif
                }
            }
            #if os(macOS)
            // Mac list footers keep to one line, so the note sits under the list.
            .safeAreaInset(edge: .bottom) {
                note
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            #endif
            .animation(.default, value: folders)
            .navigationTitle(host.workspace(workspaceID)?.name ?? "Folders")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                #if os(iOS)
                if host.isLocal {
                    ToolbarItem(placement: .cancellationAction) {
                        EditButton()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", role: .confirm) { dismiss() }
                }
                #else
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", role: .close) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
                #endif
                if host.isLocal {
                    ToolbarItem {
                        Button("Add Folders…", systemImage: "folder.badge.plus") { showingFolderImporter = true }
                    }
                }
            }
        }
        #if os(macOS)
        .frame(width: 420, height: 360)
        #endif
        .fileImporter(isPresented: $showingFolderImporter, allowedContentTypes: [.folder], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            send(folders + urls.map { $0.path(percentEncoded: false) })
        }
    }

    private var note: Text {
        Text(host.isLocal
            ? "Agents start in the primary folder and commands run there. Drag a folder to the top to make it primary."
            : "Agents start in the primary folder and commands run there. Change folders in Diffs on \(host.name).")
    }

    private func send(_ folders: [String]) {
        host.send(.workspace(id: workspaceID, action: .setFolders(folders)))
    }
}

/// A folder's name and path, marked when it's the primary one.
private struct FolderRow: View {
    let path: String
    let isPrimary: Bool
    let canRemove: Bool
    let remove: () -> Void

    var body: some View {
        HStack {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading) {
                Text(URL(filePath: path).lastPathComponent)
                Text(path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer()
            if isPrimary {
                Text("Primary")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            #if os(macOS)
            if canRemove {
                Button("Remove", systemImage: "minus.circle.fill", action: remove)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
            #endif
        }
        #if os(iOS)
        .swipeActions {
            if canRemove {
                Button("Remove", systemImage: "trash", role: .destructive, action: remove)
            }
        }
        #endif
    }
}
