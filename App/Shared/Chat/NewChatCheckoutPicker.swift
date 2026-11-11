import AtriumClient
import AtriumProtocol
import SwiftUI

/// Picks where a new chat works in its project's repository: on the branch
/// the project folder has checked out, in a new worktree its agent names, or
/// on a new branch. Shown only for a project folder that is one repository.
struct NewChatCheckoutPicker: View {
    @State private var isNamingBranch = false
    @State private var branchName = ""
    let host: HostClient
    let draft: TaskDraft

    var body: some View {
        if let repository = host.startingRepository(in: draft.workspaceID) {
            let currentBranch = repository.branchName ?? "Detached HEAD"
            let title = title(currentBranch: currentBranch)
            Menu {
                Picker("Checkout", selection: Binding(
                    get: { draft.checkout },
                    set: { checkout in host.updateDraft(draft.id) { $0.checkout = checkout } }
                )) {
                    Label(currentBranch, systemImage: "arrow.triangle.branch")
                        .tag(TaskStartCheckout?.none)
                    if case .newBranch(let name) = draft.checkout {
                        Label("\(name) (New)", systemImage: "arrow.triangle.branch")
                            .tag(draft.checkout)
                    }
                    Label("New Worktree", systemImage: "folder.badge.plus")
                        .tag(TaskStartCheckout?.some(.newWorktree))
                }
                .pickerStyle(.inline)
                .labelsHidden()
                Button("New Branch…", systemImage: "plus") {
                    branchName = ""
                    isNamingBranch = true
                }
            } label: {
                NewChatPickerLabel(title: title) {
                    Image(systemName: draft.checkout == .newWorktree ? "folder.badge.plus" : "arrow.triangle.branch")
                        .resizable()
                        .scaledToFit()
                }
            }
            .menuOrder(.fixed)
            .accessibilityLabel("Branch")
            .accessibilityValue(title)
            .alert("New Branch", isPresented: $isNamingBranch) {
                TextField("Branch name", text: $branchName)
                Button("Create", action: chooseNewBranch)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The chat starts on a new branch from “\(currentBranch)”, switched to in the project folder.")
            }
        }
    }

    private func title(currentBranch: String) -> String {
        switch draft.checkout {
        case nil: currentBranch
        case .newWorktree: "New Worktree"
        case .newBranch(let name): name
        }
    }

    private func chooseNewBranch() {
        let name = branchName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        host.updateDraft(draft.id) { $0.checkout = .newBranch(name) }
    }
}
