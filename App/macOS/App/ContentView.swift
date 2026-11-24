import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @State private var searchText = ""
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @State private var showingOnboarding = false
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        @Bindable var app = app
        NavigationSplitView(columnVisibility: $app.sidebarVisibility) {
            TaskListView(searchText: searchText)
                .navigationSplitViewColumnWidth(min: 160, ideal: 200, max: 300)
                .searchable(text: $searchText, placement: .sidebar, prompt: "Filter tasks or projects")
                .searchFocused($isSearchFocused)
        } detail: {
            if app.selectedTasks.count > 1 {
                MultipleTasksSelectedView()
            } else if let task = app.selectedTask {
                TaskDetailView(item: task)
            } else {
                NewChatUnavailableView { app.selection = $0 }
            }
        }
        .toolbar {
            // The sidebar's own control goes with it, so a hidden sidebar
            // leaves the same control at the window's leading edge.
            if app.sidebarVisibility == .detailOnly {
                ToolbarItem(placement: .navigation) {
                    SidebarMenu()
                }
            }
        }
        .task(id: app.sidebarSearchFocusRequest) {
            guard app.sidebarSearchFocusRequest > 0 else { return }
            if app.sidebarVisibility == .detailOnly {
                withAnimation { app.sidebarVisibility = .automatic }
                // The field exists once the sidebar has slid in.
                guard (try? await Task.sleep(for: .milliseconds(250))) != nil else { return }
            }
            isSearchFocused = true
        }
        .inspector(isPresented: $app.showingInspector) {
            InspectorView(project: app.selectedProject)
        }
        // The selected project's Git status and commands back the inspector,
        // the editor's change markers and the Run command alike.
        .followsProjectScope(of: app.selectedTask)
        .task(id: app.selectedProject?.id) {
            guard let project = app.selectedProject else { return }
            await project.host.follow(.commands(workspaceID: project.workspaceID))
        }
        .onChange(of: app.selectedTask?.id, initial: true) { _, ref in
            app.hosts.setVisibleTask(ref)
        }

        .onChange(of: scenePhase, initial: true) { _, phase in
            app.hosts.setActive(phase == .active)
            if phase == .active { app.localHost?.send(.refreshTasks) }
        }
        .onChange(of: app.hosts.pendingTask) { _, ref in
            guard let ref else { return }
            app.selection = ref
            app.hosts.pendingTask = nil
            #if DEBUG
            // Development builds can show an inspector tab at launch: files, git, search or commands.
            if let tab = ProcessInfo.processInfo.environment["ATRIUM_DEBUG_TAB"].flatMap(InspectorTab.init(debugName:)) {
                app.showInspector(tab)
            }
            #endif
        }
        #if DEBUG
        .task { await app.hosts.applyDebugLaunch() }
        #endif
        .focusedSceneValue(\.isMainWindow, true)
        // A pairing link from another host's Settings connects this Mac to it,
        // and ChatGPT's request to connect asks first.
        .onOpenURL { url in app.handle(url) }
        .alert(
            "Connect ChatGPT to Atrium?",
            isPresented: Binding(get: { app.pendingAgentConnection != nil }, set: { if !$0 { app.pendingAgentConnection = nil } }),
            presenting: app.pendingAgentConnection
        ) { request in
            Button("Full Access") { app.approve(request, access: .upTo(.fullAccess)) }
            Button("Supervised") { app.approve(request, access: .upTo(.supervised)) }
            Button("Read Only") { app.approve(request, access: .readOnly) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Full Access: ChatGPT can start and prompt sessions on this Mac in any mode, and answer their questions and approvals. Supervised: sessions it hands work to ask you before edits and commands, and it can't approve them. Read Only: it can only list and read sessions. Remote access turns on so it can reach this Mac. Remove it any time in Settings → Remote.")
        }
        .alert(
            "Couldn’t connect ChatGPT",
            isPresented: Binding(get: { app.agentConnectionError != nil }, set: { if !$0 { app.agentConnectionError = nil } }),
            presenting: app.agentConnectionError
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
        // Opened from the sidebar menu, which a hidden sidebar takes away.
        .sheet(isPresented: $app.showingProjects) { ProjectsSheet(hosts: app.hosts) }
        .sheet(isPresented: $showingOnboarding) {
            hasCompletedOnboarding = true
        } content: {
            OnboardingView()
        }
        .task {
            if !hasCompletedOnboarding { showingOnboarding = true }
        }
        .alert(
            "Replace running command?",
            isPresented: Binding(get: { app.pendingRunReplacement != nil }, set: { if !$0 { app.pendingRunReplacement = nil } }),
            presenting: app.pendingRunReplacement
        ) { pending in
            Button("Replace", role: .confirm) { pending.project.run(pending.command) }
            Button("Cancel", role: .cancel) {}
        } message: { pending in
            Text("“\(pending.command.title)” is currently running. Replacing will stop it and start a new instance.")
        }
    }
}
