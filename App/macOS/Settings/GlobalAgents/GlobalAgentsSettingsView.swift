import AtriumProtocol
import SwiftUI

enum GlobalAgentsRoute: Hashable {
    case instructions
    case skill(String)
}

/// Manages `~/.agents` (`AGENTS.md` and `skills/`) inside Settings.
/// Provider symlink controls live in each provider's detail view under `Agents`.
struct GlobalAgentsSettingsView: View {
    @Bindable var store: GlobalAgentsStore
    @State private var path: [GlobalAgentsRoute] = []
    @State private var showingNewSkill = false
    @State private var searchText = ""

    private var trimmedSearch: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var filteredSkills: [GlobalAgentsStore.GlobalSkill] {
        guard !trimmedSearch.isEmpty else { return store.skills }
        return store.skills.filter {
            $0.name.localizedCaseInsensitiveContains(trimmedSearch) ||
            $0.description.localizedCaseInsensitiveContains(trimmedSearch)
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            rootContent
                .navigationDestination(for: GlobalAgentsRoute.self) { route in
                    switch route {
                    case .instructions:
                        GlobalInstructionsEditorView(store: store)
                    case .skill(let folderName):
                        if let skill = store.skills.first(where: { $0.folderName == folderName }) {
                            GlobalSkillDetailView(store: store, skill: skill) {
                                if !path.isEmpty { path.removeLast() }
                            }
                        } else {
                            ContentUnavailableView(
                                "Skill Not Found",
                                systemImage: "wand.and.stars",
                                description: Text("“\(folderName)” is no longer in ~/.agents/skills.")
                            )
                        }
                    }
                }
        }
        .sheet(isPresented: $showingNewSkill) {
            NewGlobalSkillSheet(store: store) { created in
                path.append(GlobalAgentsRoute.skill(created.folderName))
            }
        }
        .onAppear {
            store.refresh()
        }
    }

    private var rootContent: some View {
        Group {
            if !trimmedSearch.isEmpty && filteredSkills.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else {
                Form {
                    if trimmedSearch.isEmpty {
                        instructionsSection
                    }
                    skillsSection
                }
                .formStyle(.grouped)
            }
        }
        .navigationTitle("Skills & Rules")
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search skills")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    showingNewSkill = true
                } label: {
                    Label("New Skill", systemImage: "plus")
                }
                .help("Create a new skill in ~/.agents/skills")

                Button {
                    store.revealInFinder(store.agentsDirectory)
                } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                }
                .help("Reveal ~/.agents in Finder")
            }

            ToolbarSpacer(.fixed, placement: .primaryAction)

            ToolbarItem(placement: .primaryAction) {
                Button {
                    store.refresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Rescan ~/.agents")
            }
        }
    }

    private var instructionsSection: some View {
        Section("Global Instructions") {
            if store.hasAgentsMD {
                NavigationLink(value: GlobalAgentsRoute.instructions) {
                    LabeledContent {
                        EmptyView()
                    } label: {
                        Label("AGENTS.md", systemImage: "doc.text")
                        Text(instructionsSubtitle)
                    }
                }
            } else {
                LabeledContent {
                    Button("Create…") {
                        store.createAgentsMD()
                        if store.hasAgentsMD { path.append(GlobalAgentsRoute.instructions) }
                    }
                } label: {
                    Label("AGENTS.md", systemImage: "doc.text")
                    Text("Not created in ~/.agents yet")
                }
            }
        }
    }

    private var skillsSection: some View {
        Section {
            if store.skills.isEmpty {
                LabeledContent {
                    Button("New Skill…") { showingNewSkill = true }
                } label: {
                    Text("No global skills")
                    Text("Skills in ~/.agents/skills appear here.")
                }
            } else {
                ForEach(filteredSkills) { skill in
                    NavigationLink(value: GlobalAgentsRoute.skill(skill.folderName)) {
                        LabeledContent {
                            EmptyView()
                        } label: {
                            Text(skill.name)
                            if !skill.description.isEmpty {
                                Text(skill.description)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            }
        } header: {
            Text(store.skills.isEmpty ? "Skills" : "Skills (\(filteredSkills.count))")
        }
    }

    private var instructionsSubtitle: String {
        var parts = ["~/.agents/AGENTS.md", "\(store.agentsMDLineCount) \(store.agentsMDLineCount == 1 ? "line" : "lines")"]
        if let modified = store.agentsMDModifiedAt {
            parts.append("Edited \(modified.formatted(.relative(presentation: .named)))")
        }
        return parts.joined(separator: " · ")
    }
}

/// One symlink row (Instructions or Skills) displayed in a provider's detail view under `Agents`.
struct ProviderLinkRow: View {
    let store: GlobalAgentsStore
    let provider: AgentProvider
    let target: GlobalAgentsStore.ProviderTarget

    var body: some View {
        LabeledContent {
            trailingControl
        } label: {
            Text(target.kind.rawValue)
            Text(subtitle)
        }
    }

    private var subtitle: String {
        switch target.status {
        case .native, .linked, .notLinked:
            target.displayProviderPath
        case .existingFile(let lines, _):
            "\(target.displayProviderPath) · Existing file (\(lines) \(lines == 1 ? "line" : "lines"))"
        case .existingFolder(let items):
            items.isEmpty
                ? "\(target.displayProviderPath) · Empty folder"
                : "\(target.displayProviderPath) · \(items.count) existing \(items.count == 1 ? "item" : "items")"
        case .otherSymlink(let destination):
            "\(target.displayProviderPath) → \(destination)"
        case .brokenSymlink:
            "\(target.displayProviderPath) · Broken link"
        }
    }

    @ViewBuilder
    private var trailingControl: some View {
        switch target.status {
        case .native:
            Text("Built-in")
                .foregroundStyle(.secondary)

        case .linked:
            HStack(spacing: 8) {
                Text("Linked")
                    .foregroundStyle(.secondary)

                Menu {
                    Button("Copy Symlink Command", systemImage: "doc.on.doc") {
                        store.copySymlinkCommand(for: target)
                    }
                    Button("Reveal in Finder", systemImage: "folder") {
                        store.revealInFinder(target.providerURL)
                    }
                    Divider()
                    Button("Unlink", systemImage: "link.badge.minus", role: .destructive) {
                        store.unlink(provider: provider, kind: target.kind)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }

        case .notLinked:
            Button("Link") {
                store.requestLink(provider: provider, kind: target.kind)
            }

        case .brokenSymlink:
            Button("Repair") {
                store.requestLink(provider: provider, kind: target.kind)
            }

        case .existingFile, .existingFolder, .otherSymlink:
            Button("Link…") {
                store.requestLink(provider: provider, kind: target.kind)
            }
        }
    }
}
