import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @State private var searchText = ""
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @State private var showingOnboarding = false

    var body: some View {
        @Bindable var app = app
        NavigationSplitView(columnVisibility: $app.sidebarVisibility) {
            TaskListView(searchText: searchText)
                .navigationSplitViewColumnWidth(min: 160, ideal: 200, max: 300)
                .searchable(text: $searchText, placement: .sidebar, prompt: "Filter tasks or projects")
        } detail: {
            if let task = app.selectedTask {
                TaskDetailView(item: task)
            } else {
                ContentUnavailableView(
                    "No Task Selected",
                    systemImage: "sidebar.left",
                    description: Text("Select a task or start a new chat.")
                )
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
            }
        }
        .inspector(isPresented: $app.showingInspector) {
            if let project = app.selectedProject {
                InspectorView(project: project)
                    .inspectorColumnWidth(min: 240, ideal: 240, max: 360)
            } else {
                ContentUnavailableView("No Inspector", systemImage: "sidebar.right")
            }
        }
        // The selected project's Git status and commands back the inspector,
        // the editor's change markers and the Run command alike.
        .task(id: app.selectedProject?.gitScope) {
            guard let project = app.selectedProject else { return }
            await project.host.follow(.git(project.gitScope))
        }
        .task(id: app.selectedProject?.id) {
            guard let project = app.selectedProject else { return }
            await project.host.follow(.commands(workspaceID: project.workspaceID))
        }
        .onChange(of: app.selection, initial: true) { _, selection in
            app.hosts.setVisibleTask(selection)
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
                app.selectedProject?.selectedTab = tab
            }
            #endif
        }
        #if DEBUG
        .task { await app.hosts.applyDebugLaunch() }
        #endif
        .focusedSceneValue(\.isMainWindow, true)
        // A pairing link from another host's Settings connects this Mac to it.
        .onOpenURL { url in app.hosts.handle(url) }
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
            Button("Replace", role: .confirm) { pending.project.send(.run, to: pending.command) }
            Button("Cancel", role: .cancel) {}
        } message: { pending in
            Text("“\(pending.command.title)” is currently running. Replacing will stop it and start a new instance.")
        }
    }
}
