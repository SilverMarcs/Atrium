import SwiftUI

struct TaskDetailView: View {
    let session: TaskSession
    @State private var showingScratchPad = false

    private var workspace: Workspace { session.workspace }

    var body: some View {
        TaskTerminalView(session: session)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                BottomSheetView(directoryURL: workspace.url)
            }
            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button("Scratch Pad", systemImage: "note.text") {
                        showingScratchPad = true
                    }
                    .keyboardShortcut(".")
                }
            }
            .sheet(isPresented: $showingScratchPad) {
                ScratchPadSheet(workspace: workspace)
            }
            .navigationTitle(String(session.thread.title.prefix(50)))
            .navigationSubtitle(workspace.directory.replacing(NSHomeDirectory(), with: "~"))
            .environment(workspace.editorPanel)
            .environment(\.showInFileTree) { url in
                workspace.inspectorState.revealInFileTree(url, relativeTo: workspace.url)
            }
    }
}
