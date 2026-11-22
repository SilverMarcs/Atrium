import AppKit
import AtriumClient
import AtriumProtocol
import SwiftUI

enum SettingsPane: String, CaseIterable, Identifiable {
    case general
    case remote
    case updates
    case agents
    case globalAgents
    case integrations

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "General"
        case .remote: "Remote"
        case .updates: "Updates"
        case .agents: "Agents"
        case .globalAgents: "Skills & Rules"
        case .integrations: "Integrations"
        }
    }

    var symbolName: String {
        switch self {
        case .general: "gearshape.fill"
        case .remote: "network"
        case .updates: "arrow.down.circle.fill"
        case .agents: "puzzlepiece.extension.fill"
        case .globalAgents: "doc.text.fill"
        case .integrations: "point.3.connected.trianglepath.dotted"
        }
    }

    var badgeColor: Color {
        switch self {
        case .general: Color(nsColor: .systemGray)
        case .remote: .blue
        case .updates: .indigo
        case .agents: .teal
        case .globalAgents: .purple
        case .integrations: .green
        }
    }

    static let appPanes: [SettingsPane] = [.general, .remote, .updates]
    static let agentPanes: [SettingsPane] = [.agents, .globalAgents, .integrations]
}

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var selection: SettingsPane? = .general
    @State private var globalAgents = GlobalAgentsStore()

    private var installedProviders: [AgentProvider] {
        (app.localHost?.tasks?.providers ?? []).filter(\.isAvailable).map(\.provider)
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(selection: $selection) {
                Section {
                    ForEach(SettingsPane.appPanes) { pane in
                        sidebarRow(for: pane)
                    }
                }

                Section("Agents") {
                    ForEach(SettingsPane.agentPanes) { pane in
                        sidebarRow(for: pane)
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 185, ideal: 215, max: 260)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            Group {
                switch selection ?? .general {
                case .general:
                    GeneralSettingsView()
                case .remote:
                    RemoteSettingsView()
                case .updates:
                    UpdatesSettingsView()
                case .agents:
                    AgentsSettingsView(globalAgents: globalAgents)
                case .globalAgents:
                    GlobalAgentsSettingsView(store: globalAgents)
                case .integrations:
                    IntegrationsSettingsView()
                }
            }
            .id(selection ?? .general)
            .frame(minWidth: 460, idealWidth: 540, maxWidth: .infinity, minHeight: 480, idealHeight: 580, maxHeight: .infinity)
        }
        .navigationSplitViewStyle(.balanced)
        .background(SettingsWindowConfigurator())
        .sheet(item: $globalAgents.pendingConflict) { conflict in
            ProviderLinkConflictSheet(store: globalAgents, conflict: conflict)
        }
        .alert("Skills & Rules", isPresented: Binding(
            get: { globalAgents.actionError != nil },
            set: { if !$0 { globalAgents.actionError = nil } }
        )) {
            Button("OK", role: .cancel) { globalAgents.actionError = nil }
        } message: {
            Text(globalAgents.actionError ?? "")
        }
        .onAppear {
            globalAgents.refresh()
        }
        .onChange(of: installedProviders, initial: true) { _, providers in
            globalAgents.installedProviders = providers
        }
    }

    private func sidebarRow(for pane: SettingsPane) -> some View {
        HStack(spacing: 8) {
            Image(systemName: pane.symbolName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(pane.badgeColor.gradient, in: RoundedRectangle(cornerRadius: 5, style: .continuous))

            Text(pane.title)
                .lineLimit(1)
        }
        .padding(.vertical, 1)
        .badge(pane == .agents ? globalAgents.unlinkedTargetCount : 0)
        .tag(pane)
    }
}

/// Holds the toolbar's height on panes without buttons, so the title doesn't jump between panes.
struct ToolbarHeightPlaceholder: ToolbarContent {
    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Color.clear
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)
        }
        .sharedBackgroundVisibility(.hidden)
    }
}

/// Keeps the Settings sidebar resizable but never collapsed, like System Settings.
/// SwiftUI re-enables collapsing on updates, so the split view item is observed.
private struct SettingsWindowConfigurator: NSViewRepresentable {
    final class Coordinator {
        weak var observedSidebar: NSSplitViewItem?
        var observations: [NSKeyValueObservation] = []

        func attach(to window: NSWindow) {
            guard let splitVC = findSplitViewController(in: window),
                  let sidebar = splitVC.splitViewItems.first else { return }

            lockSidebar(sidebar)

            guard observedSidebar !== sidebar else { return }
            observedSidebar = sidebar
            observations = [
                sidebar.observe(\.canCollapse, options: [.new]) { item, _ in
                    MainActor.assumeIsolated {
                        if item.canCollapse { item.canCollapse = false }
                    }
                },
                sidebar.observe(\.canCollapseFromWindowResize, options: [.new]) { item, _ in
                    MainActor.assumeIsolated {
                        if item.canCollapseFromWindowResize { item.canCollapseFromWindowResize = false }
                    }
                },
                sidebar.observe(\.isCollapsed, options: [.new]) { item, _ in
                    MainActor.assumeIsolated {
                        if item.isCollapsed { item.isCollapsed = false }
                    }
                },
            ]
        }

        private func lockSidebar(_ sidebar: NSSplitViewItem) {
            if sidebar.canCollapse { sidebar.canCollapse = false }
            if sidebar.canCollapseFromWindowResize { sidebar.canCollapseFromWindowResize = false }
            if sidebar.isCollapsed { sidebar.isCollapsed = false }
            sidebar.minimumThickness = 185
            sidebar.maximumThickness = 260
        }

        private func findSplitViewController(in window: NSWindow) -> NSSplitViewController? {
            if let vc = findSplitVC(in: window.contentViewController) { return vc }
            if let contentView = window.contentView,
               let splitView = findSplitView(in: contentView),
               let vc = splitView.delegate as? NSSplitViewController {
                return vc
            }
            return nil
        }

        private func findSplitVC(in controller: NSViewController?) -> NSSplitViewController? {
            guard let controller else { return nil }
            if let split = controller as? NSSplitViewController { return split }
            for child in controller.children {
                if let found = findSplitVC(in: child) { return found }
            }
            return nil
        }

        private func findSplitView(in view: NSView) -> NSSplitView? {
            if let split = view as? NSSplitView { return split }
            for subview in view.subviews {
                if let found = findSplitView(in: subview) { return found }
            }
            return nil
        }
    }

    private final class ConfiguratorView: NSView {
        var onWindow: ((NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window else { return }
                self.onWindow?(window)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = ConfiguratorView()
        view.onWindow = { [coordinator = context.coordinator] window in
            coordinator.attach(to: window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let view = nsView as? ConfiguratorView {
            view.onWindow = { [coordinator = context.coordinator] window in
                coordinator.attach(to: window)
            }
            if let window = view.window {
                DispatchQueue.main.async {
                    context.coordinator.attach(to: window)
                }
            }
        }
    }
}
