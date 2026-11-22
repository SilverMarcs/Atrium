import AtriumClient
import AtriumProtocol
import SwiftUI

/// Picks one of a project's folders, in the order
/// `ProjectScope.pickableFolders` gives. Toggles rather than a picker, since
/// only a toggle's label keeps the branch as the menu item's subtitle.
struct FolderPicker: View {
    let scope: ProjectScope
    @Binding var selection: URL?

    var body: some View {
        let (unchanged, changed) = scope.pickableFolders
        ForEach(unchanged) { folder in
            row(folder)
        }
        if !changed.isEmpty {
            Section("Changed in This Task") {
                ForEach(changed) { folder in
                    row(folder)
                }
            }
        }
    }

    private func row(_ folder: ProjectFolder) -> some View {
        Toggle(isOn: Binding(get: { selection == folder.key }, set: { _ in selection = folder.key })) {
            Text(folder.name)
            if let status = folder.status {
                Text(status.branchName ?? "Detached HEAD")
            }
        }
    }
}
