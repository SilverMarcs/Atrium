import AtriumClient
import AtriumProtocol
import SwiftUI

/// A task's chat and, on this Mac's own host, its terminal, above its
/// project's editor panel.
struct TaskDetailView: View {
    let item: HostTask
    @Environment(AppModel.self) private var app
    @SceneStorage("taskPresentation") private var presentation = "chat"
    @State private var showingScratchPad = false

    private var task: WireTask { item.task }
    private var models: [AgentModel] { item.host.models(for: task.provider) }
    private var project: Project? {
        task.workspaceID.flatMap { app.project(WorkspaceRef(hostID: item.host.id, workspaceID: $0)) }
    }
    /// The task's terminal, which only its own host shows.
    private var session: TaskSession? {
        item.host.isLocal ? app.terminals.session(for: task.id) : nil
    }
    private var showsTerminal: Bool { session != nil && presentation == "terminal" }

    var body: some View {
        ZStack {
            if let session {
                if session.isTerminalAttached {
                    TaskTerminalView(session: session, terminals: app.terminals, acceptsInputFocus: showsTerminal)
                        .scrollEdgeEffectHidden()
                        .opacity(showsTerminal ? 1 : 0)
                        .allowsHitTesting(showsTerminal)
                        .accessibilityHidden(!showsTerminal)
                } else if showsTerminal {
                    if let error = session.terminalError {
                        ContentUnavailableView {
                            Label("Couldn’t Attach Terminal", systemImage: "terminal")
                        } description: {
                            Text(error)
                        } actions: {
                            Button("Retry") { Task { await app.terminals.attachTerminal(to: session) } }
                        }
                    } else {
                        ProgressView("Attaching terminal…")
                    }
                }
            }
            if !showsTerminal {
                SessionChatView(item: item, project: project)
                    .id(item.id)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: "\(task.id):\(showsTerminal)") {
            session?.isTerminalVisible = showsTerminal
            if showsTerminal, let session { await app.terminals.attachTerminal(to: session) }
        }
        .onDisappear { session?.isTerminalVisible = false }
        #if DEBUG
        .onAppear {
            // Development builds can open on the terminal with ATRIUM_DEBUG_PRESENTATION.
            if let debug = ProcessInfo.processInfo.environment["ATRIUM_DEBUG_PRESENTATION"] { presentation = debug }
        }
        #endif
        .task(id: task.hasUnreadResult) {
            // Viewing a finished task reads it, on whichever host it's on.
            if task.hasUnreadResult { item.host.send(.task(id: task.id, action: .viewed)) }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let project {
                BottomSheetView(project: project, showsCollapsedHeader: showsTerminal)
            }
        }
        .toolbarBackgroundVisibility(showsTerminal ? .hidden : .automatic, for: .windowToolbar)
        .toolbar {
            if !showsTerminal {
                ToolbarItem {
                    TaskModelMenu(
                        provider: task.provider, selection: task.modelSelection, models: models,
                        perform: { item.host.send(.task(id: task.id, action: $0)) }, showsToolbarLabel: true
                    )
                    .disabled(models.isEmpty)
                }
            }
            if session != nil {
                ToolbarItem {
                    Picker("Session View", selection: $presentation) {
                        Label("Chat", systemImage: "bubble.left").tag("chat")
                        Label("Terminal", systemImage: "terminal").tag("terminal")
                    }
                    .pickerStyle(.segmented)
                    .labelStyle(.iconOnly)
                }
            }
            if project != nil {
                ToolbarItem(placement: .navigation) {
                    Button("Scratch Pad", systemImage: "note.text") { showingScratchPad = true }
                        .keyboardShortcut(".")
                }
            }
        }
        .sheet(isPresented: $showingScratchPad) {
            if let workspaceID = task.workspaceID {
                ScratchPadSheet(host: item.host, workspaceID: workspaceID)
            }
        }
        .navigationTitle(String(task.title.prefix(50)))
        .navigationSubtitle(subtitle)
        .focusedSceneValue(\.editorPanel, project?.editor)
    }

    private var subtitle: String {
        let directory = project?.workspace?.directory ?? task.directory
        return item.host.isLocal ? directory : "\(item.host.name) \(directory)"
    }
}
