import Foundation
import Observation

@MainActor
@Observable
final class ComposeProjectPickerModel {
    var searchText = ""

    func filteredWorkspaces(in workspaces: [Workspace]) -> [Workspace] {
        guard !searchText.isEmpty else { return workspaces }
        return workspaces.filter {
            $0.name.localizedStandardContains(searchText)
                || $0.directory.localizedStandardContains(searchText)
        }
    }

    func validSelection(_ selection: UUID?, in workspaces: [Workspace]) -> UUID? {
        workspaces.first(where: { $0.id == selection })?.id ?? workspaces.first?.id
    }

    func movedSelection(_ selection: UUID?, by offset: Int, in workspaces: [Workspace]) -> UUID? {
        guard !workspaces.isEmpty else { return nil }
        guard let index = workspaces.firstIndex(where: { $0.id == selection }) else {
            return workspaces.first?.id
        }
        let nextIndex = min(max(index + offset, 0), workspaces.count - 1)
        return workspaces[nextIndex].id
    }
}
