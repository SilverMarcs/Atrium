import SwiftUI
import UniformTypeIdentifiers

struct ComposeProjectPickerView: View {
    let workspaces: [Workspace]
    @Binding var workspaceID: UUID?
    @Bindable var model: ComposeProjectPickerModel
    let onSubmit: () -> Void
    let onDelete: (Workspace) -> Void
    @State private var didInitialScroll = false
    @FocusState private var isProjectListFocused: Bool

    var body: some View {
        let projects = model.filteredWorkspaces(in: workspaces)

        ScrollViewReader { proxy in
            List(selection: $workspaceID) {
                ForEach(projects) { workspace in
                    HStack {
                        ThreadWorkspaceIcon(workspace: workspace)
                            .scaleEffect(1.5)
                        VStack(alignment: .leading) {
                            Text(workspace.name)
                            Text(workspace.directory.replacing(NSHomeDirectory(), with: "~"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .padding(.leading, 8)
                    .tag(workspace.id)
                    .contextMenu {
                        Menu {
                            Picker("Project Type", selection: Bindable(workspace).projectType) {
                                ForEach(ProjectType.allCases, id: \.self) { type in
                                    Label {
                                        Text(type.displayName)
                                    } icon: {
                                        if !type.iconName.isEmpty {
                                            Image(type.iconName)
                                                .resizable()
                                                .aspectRatio(contentMode: .fit)
                                                .frame(width: 18, height: 18)
                                        }
                                    }
                                    .tag(type)
                                }
                            }
                            .pickerStyle(.inline)
                            .labelsHidden()

                            Divider()

                            Button("Auto-Detect") {
                                workspace.detectProjectType()
                            }
                        } label: {
                            Label("Project Type", systemImage: "shippingbox")
                        }

                        Button("Choose Icon…", systemImage: "photo") {
                            model.iconWorkspace = workspace
                            model.showingIconImporter = true
                        }

                        if workspace.customIconFilename != nil {
                            Button("Reset Icon", systemImage: "arrow.uturn.backward") {
                                workspace.clearCustomIcon()
                            }
                        }

                        Divider()
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            onDelete(workspace)
                        }
                    }
                }
            }
            .contentMargins(10, for: .scrollContent)
            .accessibilityLabel("Projects")
            .focused($isProjectListFocused)
            .onKeyPress(characters: .alphanumerics.union(.punctuationCharacters).union(.symbols).union(.whitespaces)) { key in
                guard key.modifiers.intersection([.command, .control]).isEmpty,
                      key.key != .tab else { return .ignored }
                model.searchText.append(key.characters)
                return .handled
            }
            // macOS Backspace sends DEL (0x7F); SwiftUI's .delete represents BS (0x08).
            .onKeyPress(keys: [.delete, KeyEquivalent("\u{7F}")], phases: [.down, .repeat]) { key in
                guard key.modifiers.intersection([.command, .control, .option]).isEmpty,
                      !model.searchText.isEmpty else { return .ignored }
                model.searchText.removeLast()
                return .handled
            }
            .searchable(text: $model.searchText, prompt: "Search projects")
            .onSubmit(of: .search, onSubmit)
            .onKeyPress(keys: [.upArrow, .downArrow], phases: [.down, .repeat]) { key in
                guard key.modifiers.intersection([.command, .control, .option]).isEmpty else { return .ignored }
                workspaceID = model.movedSelection(workspaceID, by: key.key == .downArrow ? 1 : -1, in: projects)
                return .handled
            }
            .overlay {
                if workspaces.isEmpty {
                    ContentUnavailableView("No Projects", systemImage: "folder", description: Text("Add a project to start a task."))
                } else if projects.isEmpty {
                    ContentUnavailableView.search(text: model.searchText)
                }
            }
            .onChange(of: model.searchText) {
                workspaceID = projects.first?.id
                if let workspaceID { proxy.scrollTo(workspaceID, anchor: .top) }
            }
            .onChange(of: projects.map(\.id)) {
                workspaceID = model.validSelection(workspaceID, in: projects)
            }
            .onChange(of: workspaceID) {
                workspaceID = model.validSelection(workspaceID, in: projects)
            }
            .task(id: [workspaceID] + projects.map { Optional($0.id) }) {
                guard let workspaceID else { return }
                if !didInitialScroll {
                    do {
                        // Let the sheet finish laying out before revealing the current project.
                        try await Task.sleep(for: .milliseconds(100))
                    } catch { return }
                    didInitialScroll = true
                }
                proxy.scrollTo(workspaceID)
            }
        }
        .fileImporter(
            isPresented: $model.showingIconImporter,
            allowedContentTypes: [.png, .jpeg, .icns]
        ) { result in
            model.importIcon(result)
        }
        .alert("Couldn’t Set Project Icon", isPresented: $model.showingIconError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(model.iconError)
        }
        .defaultFocus($isProjectListFocused, true)
        .onAppear { isProjectListFocused = true }
    }
}
