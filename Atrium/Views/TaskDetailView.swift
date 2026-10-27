import SwiftUI

struct TaskDetailView: View {
  let session: TaskSession
  @Environment(AgentIntegrationStore.self) private var integrations
  @Environment(TaskSessionController.self) private var sessions
  @Environment(WorkspaceStore.self) private var workspaces
  @SceneStorage("taskPresentation") private var presentation = "terminal"
  @State private var showingScratchPad = false

  private var workspace: Workspace { session.workspace }
  private var thread: AgentThread {
    integrations.threads.first { $0.id == session.id } ?? session.thread
  }
  private var modelSelection: TaskModelSelection {
    TaskModelSelection(
      model: thread.model,
      reasoningEffort: thread.reasoningEffort,
      isFastMode: thread.isFastMode == true,
      canSelectModel: sessions.menuState(for: thread).allowed.contains(.selectModel)
    )
  }

  var body: some View {
    ZStack {
      TaskTerminalView(session: session, acceptsInputFocus: presentation == "terminal")
        .scrollEdgeEffectHidden()
        .opacity(presentation == "terminal" ? 1 : 0)
        .allowsHitTesting(presentation == "terminal")
        .accessibilityHidden(presentation != "terminal")
      if presentation == "chat" {
        SessionChatView(session: session)
          .id(session.id)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .safeAreaInset(edge: .bottom, spacing: 0) {
      BottomSheetView(directoryURL: workspace.url)
    }
    .toolbarBackgroundVisibility(presentation == "chat" ? .automatic : .hidden, for: .windowToolbar)
    .toolbar {
      if presentation == "chat" {
        ToolbarItem(placement: .automatic) {
          TaskModelMenu(
            provider: thread.provider,
            selection: modelSelection, models: integrations.models[thread.provider] ?? [],
            perform: performModelAction, showsToolbarLabel: true
          )
          .disabled(integrations.models[thread.provider]?.isEmpty != false)
        }
      }
      ToolbarItem(placement: .automatic) {
        Picker("Session View", selection: $presentation) {
          Label("Chat", systemImage: "bubble.left").tag("chat")
          Label("Terminal", systemImage: "terminal").tag("terminal")
        }
        .pickerStyle(.segmented)
        .labelStyle(.iconOnly)
      }
      ToolbarItem(placement: .navigation) {
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

  private func performModelAction(_ action: CompanionTaskAction) {
    let service = CompanionTaskService(
      integrations: integrations, sessions: sessions, workspaces: workspaces)
    Task {
      if case .failed(let message) = await service.perform(action, onTask: session.id) {
        integrations.actionError = message
      }
    }
  }

}
