import SwiftUI

// MARK: - Action Enum

enum FileTreeAction {
    case openFile(URL)
    case revealInFinder(URL)
    case rename(FileItem)
    case commitRename(FileItem, String)
    case moveToTrash(URL)
    case duplicate(URL)
    case newFile(URL)
    case newFolder(URL)
}

// MARK: - Context Menu

struct FileTreeContextMenu: View {
    let item: FileItem
    var onAction: (FileTreeAction) -> Void = { _ in }

    private var parentURL: URL {
        item.isDirectory ? item.url : item.url.deletingLastPathComponent()
    }

    var body: some View {
        if !item.isDirectory {
            Button { onAction(.openFile(item.url)) } label: {
                Label("Open File", systemImage: "doc")
            }
        }

        Button { onAction(.revealInFinder(item.url)) } label: {
            Label("Reveal in Finder", systemImage: "folder")
        }

        Divider()

        Button { onAction(.rename(item)) } label: {
            Label("Rename", systemImage: "pencil")
        }

        Button { onAction(.duplicate(item.url)) } label: {
            Label("Duplicate", systemImage: "doc.on.doc")
        }

        Button(role: .destructive) { onAction(.moveToTrash(item.url)) } label: {
            Label("Move to Trash", systemImage: "trash")
        }

        Divider()

        Button { onAction(.newFile(parentURL)) } label: {
            Label("New File", systemImage: "doc.badge.plus")
        }

        Button { onAction(.newFolder(parentURL)) } label: {
            Label("New Folder", systemImage: "folder.badge.plus")
        }
    }
}
