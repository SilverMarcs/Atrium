import Foundation
import Observation

@MainActor
@Observable
final class ComposeProjectPickerModel {
    var searchText = ""
    var iconWorkspace: WireWorkspace?
    var showingIconImporter = false

    /// Sets a picked image as the project's icon. Only this Mac's own host
    /// can read the file, so other hosts don't offer it.
    func importIcon(_ result: Result<URL, any Error>, on host: HostClient) {
        defer { iconWorkspace = nil }
        guard let workspace = iconWorkspace, case .success(let url) = result else { return }
        host.send(.workspace(id: workspace.id, action: .setIcon(path: url.path(percentEncoded: false))))
    }

    func filteredWorkspaces(in workspaces: [WireWorkspace]) -> [WireWorkspace] {
        guard !searchText.isEmpty else { return workspaces }
        return workspaces.filter {
            $0.name.localizedStandardContains(searchText) || $0.directory.localizedStandardContains(searchText)
        }
    }

    func validSelection(_ selection: UUID?, in workspaces: [WireWorkspace]) -> UUID? {
        workspaces.first(where: { $0.id == selection })?.id ?? workspaces.first?.id
    }

    func movedSelection(_ selection: UUID?, by offset: Int, in workspaces: [WireWorkspace]) -> UUID? {
        guard !workspaces.isEmpty else { return nil }
        guard let index = workspaces.firstIndex(where: { $0.id == selection }) else { return workspaces.first?.id }
        return workspaces[min(max(index + offset, 0), workspaces.count - 1)].id
    }
}
