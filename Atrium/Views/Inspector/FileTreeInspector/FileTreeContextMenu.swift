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
    var onAction: ((FileTreeAction) -> Void)? = nil

    @Environment(\.fileTreeAction) private var fileTreeAction

    private var parentURL: URL {
        item.isDirectory ? item.url : item.url.deletingLastPathComponent()
    }

    private var currentAction: (FileTreeAction) -> Void {
        onAction ?? fileTreeAction
    }

    var body: some View {
        if !item.isDirectory {
            Button { currentAction(.openFile(item.url)) } label: {
                Label("Open File", systemImage: "doc")
            }
        }

        Button { currentAction(.revealInFinder(item.url)) } label: {
            Label("Reveal in Finder", systemImage: "folder")
        }

        Divider()

        Button { currentAction(.rename(item)) } label: {
            Label("Rename", systemImage: "pencil")
        }

        Button { currentAction(.duplicate(item.url)) } label: {
            Label("Duplicate", systemImage: "doc.on.doc")
        }

        Button(role: .destructive) { currentAction(.moveToTrash(item.url)) } label: {
            Label("Move to Trash", systemImage: "trash")
        }

        Divider()

        Button { currentAction(.newFile(parentURL)) } label: {
            Label("New File", systemImage: "doc.badge.plus")
        }

        Button { currentAction(.newFolder(parentURL)) } label: {
            Label("New Folder", systemImage: "folder.badge.plus")
        }
    }
}
