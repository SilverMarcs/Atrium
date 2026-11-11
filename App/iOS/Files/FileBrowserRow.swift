import AtriumClient
import AtriumProtocol
import SwiftUI

struct FileBrowserRow: View {
    let workspace: WorkspaceRef
    let entry: FileEntry
    var searchRoot: String?

    private var relativeDirectory: String? {
        guard let searchRoot else { return nil }
        let prefixCount = searchRoot.count + (searchRoot.hasSuffix("/") ? 0 : 1)
        return entry.path.dropFirst(prefixCount).split(separator: "/").dropLast().joined(separator: "/")
    }

    var body: some View {
        NavigationLink(value: entry.isDirectory ? Route.files(workspace, folder: entry.path) : Route.file(workspace, path: entry.path)) {
            Label {
                Text(entry.name)
                if let relativeDirectory, !relativeDirectory.isEmpty {
                    Text(relativeDirectory)
                }
            } icon: {
                Image(systemName: entry.isDirectory ? "folder.fill" : "doc")
                    .foregroundStyle(entry.isDirectory ? Color.accentColor : .secondary)
            }
            .opacity(entry.isHidden ? 0.5 : 1)
        }
    }
}
