import SwiftUI

struct WorkspaceDetailView: View {
    let chat: Chat
    let workspace: Workspace
    @State private var showingScratchPad = false

    private var directorySubtitle: String {
        workspace.directory.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    private var navigationSubtitle: String {
        guard chat.usedTokens > 0 else { return directorySubtitle }
        return "\(formatTokens(chat.usedTokens)) / \(formatTokens(chat.contextSize))"
    }

    private func formatTokens(_ count: Int) -> String {
        if count >= 1_000_000 {
            let m = Double(count) / 1_000_000
            return String(format: "%.1fM", m)
        } else if count >= 1_000 {
            let k = Double(count) / 1_000
            return String(format: "%.1fK", k)
        }
        return "\(count)"
    }

    var body: some View {
        ACPView(chat: chat)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                BottomSheetView(directoryURL: workspace.url)
            }
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button {
                        showingScratchPad = true
                    } label: {
                        Label("Scratch Pad", systemImage: "note.text")
                    }
                    .keyboardShortcut(".")
                }
            }
            .sheet(isPresented: $showingScratchPad) {
                ScratchPadSheet(workspace: workspace)
            }
            .navigationTitle(workspace.name)
            .navigationSubtitle(navigationSubtitle)
            .environment(workspace.editorPanel)
            .environment(\.showInFileTree) { url in
                workspace.inspectorState.revealInFileTree(url, relativeTo: workspace.url)
            }
    }
}
