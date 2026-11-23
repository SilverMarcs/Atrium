import AppKit
import SwiftMarkdownView
import SwiftUI

private enum DocumentEditorMode: String, CaseIterable {
    case edit
    case preview
}

/// Detail editor & Markdown preview for `~/.agents/AGENTS.md`.
struct GlobalInstructionsEditorView: View {
    let store: GlobalAgentsStore
    @State private var draft = ""
    @State private var mode: DocumentEditorMode = .edit

    private var isDirty: Bool { draft != store.agentsMDContent }

    var body: some View {
        Group {
            switch mode {
            case .edit:
                SettingsDocumentEditor(text: $draft)
                    .ignoresSafeArea(.container, edges: .top)
            case .preview:
                SettingsMarkdownPreview(markdown: draft)
            }
        }
        .navigationTitle(isDirty ? "AGENTS.md •" : "AGENTS.md")
        .navigationSubtitle("~/.agents/AGENTS.md")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                DocumentModePicker(selection: $mode)
            }

            ToolbarSpacer(.fixed, placement: .primaryAction)

            ToolbarItem(placement: .primaryAction) {
                Button {
                    store.revealInFinder(store.agentsMDURL)
                } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                }
                .help("Reveal AGENTS.md in Finder")
            }

            ToolbarSpacer(.fixed, placement: .primaryAction)

            ToolbarItem(placement: .primaryAction) {
                Button("Save") {
                    store.saveAgentsMD(draft)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!isDirty)
            }
        }
        .onAppear { draft = store.agentsMDContent }
        .onChange(of: store.agentsMDContent) { _, updated in
            if !isDirty { draft = updated }
        }
    }
}

/// Detail editor & Markdown preview for a skill in `~/.agents/skills/<name>`.
struct GlobalSkillDetailView: View {
    let store: GlobalAgentsStore
    let skill: GlobalAgentsStore.GlobalSkill
    let onDeleted: () -> Void

    @State private var selectedFilePath = "SKILL.md"
    @State private var draft = ""
    @State private var mode: DocumentEditorMode = .edit
    @State private var confirmingDelete = false

    private var selectedFile: GlobalAgentsStore.SkillFile? {
        skill.files.first(where: { $0.relativePath == selectedFilePath }) ?? skill.files.first
    }

    private var isMarkdownFile: Bool {
        selectedFile?.relativePath.lowercased().hasSuffix(".md") ?? false
    }

    private var isDirty: Bool {
        guard let selectedFile else { return false }
        return draft != selectedFile.content
    }

    private var subtitle: String {
        "~/.agents/skills/\(skill.folderName)"
    }

    var body: some View {
        Group {
            if selectedFile != nil {
                if mode == .preview && isMarkdownFile {
                    SettingsMarkdownPreview(markdown: Self.stripFrontmatter(draft))
                } else {
                    SettingsDocumentEditor(text: $draft)
                        .ignoresSafeArea(.container, edges: .top)
                }
            }
        }
        .navigationTitle(isDirty ? "\(skill.name) •" : skill.name)
        .navigationSubtitle(subtitle)
        .toolbar {
            if skill.files.count > 1 {
                ToolbarItem(placement: .primaryAction) {
                    Picker("File", selection: $selectedFilePath) {
                        ForEach(skill.files) { file in
                            Text(file.relativePath).tag(file.relativePath)
                        }
                    }
                    .labelsHidden()
                    .help("Switch file in this skill folder")
                }
            }

            if isMarkdownFile {
                ToolbarItem(placement: .primaryAction) {
                    DocumentModePicker(selection: $mode)
                }

                ToolbarSpacer(.fixed, placement: .primaryAction)
            }

            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    store.revealInFinder(skill.folderURL)
                } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                }
                .help("Reveal skill folder in Finder")

                Button(role: .destructive) {
                    confirmingDelete = true
                } label: {
                    Label("Delete Skill", systemImage: "trash")
                }
                .help("Move skill folder to Trash")
            }

            ToolbarSpacer(.fixed, placement: .primaryAction)

            ToolbarItem(placement: .primaryAction) {
                Button("Save") {
                    if let selectedFile {
                        store.saveSkillFile(selectedFile, content: draft)
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!isDirty)
            }
        }
        .onAppear { loadSelectedFile() }
        .onChange(of: selectedFilePath) { _, _ in
            loadSelectedFile()
            if !isMarkdownFile { mode = .edit }
        }
        .onChange(of: skill) { _, _ in
            if !isDirty { loadSelectedFile() }
        }
        .alert("Move “\(skill.name)” to Trash?", isPresented: $confirmingDelete) {
            Button("Move to Trash", role: .destructive) {
                store.deleteSkill(skill)
                onDeleted()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes ~/.agents/skills/\(skill.folderName) from this Mac.")
        }
    }

    private func loadSelectedFile() {
        draft = selectedFile?.content ?? ""
    }

    private static func stripFrontmatter(_ text: String) -> String {
        guard text.hasPrefix("---\n") || text.hasPrefix("---\r\n") else { return text }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for index in 1..<lines.count {
            if lines[index].trimmingCharacters(in: .whitespacesAndNewlines) == "---" {
                let body = lines[(index + 1)...].joined(separator: "\n")
                return body.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return text
    }
}

private struct DocumentModePicker: View {
    @Binding var selection: DocumentEditorMode

    var body: some View {
        Picker("Mode", selection: $selection) {
            Image(systemName: "pencil")
                .accessibilityLabel("Edit")
                .help("Edit")
                .tag(DocumentEditorMode.edit)
            Image(systemName: "doc.richtext")
                .accessibilityLabel("Preview")
                .help("Preview")
                .tag(DocumentEditorMode.preview)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }
}

/// Native Markdown preview that scrolls underneath the window toolbar with comfortable content margins.
private struct SettingsMarkdownPreview: View {
    let markdown: String

    var body: some View {
        ScrollView {
            if markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("Empty file")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                SwiftMarkdownView(markdown)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .contentMargins(20, for: .scrollContent)
    }
}

/// Edge-to-edge `NSScrollView` + `NSTextView` editor with comfortable text container insets,
/// scrolling smoothly beneath the unified toolbar with the scrollbar flush to the window edge.
private struct SettingsDocumentEditor: NSViewRepresentable {
    @Binding var text: String

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SettingsDocumentEditor
        var isUpdating = false

        init(_ parent: SettingsDocumentEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard !isUpdating, let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.automaticallyAdjustsContentInsets = true

        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.drawsBackground = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
        textView.textContainerInset = NSSize(width: 20, height: 16)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.string = text

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text {
            context.coordinator.isUpdating = true
            textView.string = text
            context.coordinator.isUpdating = false
        }
    }
}

/// Safe conflict prompt when a provider path already holds a real file, folder, or other symlink.
struct ProviderLinkConflictSheet: View {
    let store: GlobalAgentsStore
    let conflict: GlobalAgentsStore.LinkConflict
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title2)
                    .foregroundStyle(.orange)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 4) {
                    Text("\(conflict.target.displayProviderPath) already exists")
                        .font(.headline)
                    Text("\(conflict.provider.name) currently has its own \(conflict.target.kind == .instructions ? "instructions file" : "skills folder"). Choose how to link it to \(conflict.target.displaySourcePath).")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            switch conflict.target.status {
            case .existingFile(let lines, let preview):
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Current contents")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(lines) \(lines == 1 ? "line" : "lines")")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    ScrollView {
                        Text(preview.isEmpty ? "(Empty file)" : preview)
                            .font(.caption.monospaced())
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .padding(10)
                    }
                    .frame(height: 130)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator, lineWidth: 1))
                }

            case .existingFolder(let itemNames):
                VStack(alignment: .leading, spacing: 6) {
                    Text("Existing items in \(conflict.target.displayProviderPath)")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            if itemNames.isEmpty {
                                Text("Empty directory")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(itemNames, id: \.self) { name in
                                    Label(name, systemImage: "folder")
                                        .font(.caption.monospaced())
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                    }
                    .frame(maxHeight: 130)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator, lineWidth: 1))
                }

            case .otherSymlink(let destination):
                VStack(alignment: .leading, spacing: 4) {
                    Text("Currently points to")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text(destination)
                        .font(.caption.monospaced())
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator, lineWidth: 1))
                }

            default:
                EmptyView()
            }

            HStack {
                Button("Copy ln -s") {
                    store.copySymlinkCommand(for: conflict.target)
                    dismiss()
                }

                Spacer()

                Button("Cancel", role: .cancel) {
                    dismiss()
                }

                Button("Back Up & Link") {
                    store.resolveConflict(conflict, strategy: .backupAndLink)
                    dismiss()
                }

                if case .otherSymlink = conflict.target.status {
                    // Only backup & link applies for foreign symlinks.
                } else {
                    Button(conflict.target.kind == .instructions ? "Merge & Link" : "Move Skills & Link") {
                        store.resolveConflict(conflict, strategy: .mergeAndLink)
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(.top, 4)
        }
        .padding(20)
        .frame(width: 520)
    }
}

/// Modal to scaffold a new skill folder in `~/.agents/skills/`.
struct NewGlobalSkillSheet: View {
    let store: GlobalAgentsStore
    let onCreated: (GlobalAgentsStore.GlobalSkill) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var description = ""

    private var previewSlug: String {
        let slug = GlobalAgentsStore.skillFolderName(for: name)
        return slug.isEmpty ? "skill-name" : slug
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Global Skill")
                .font(.headline)

            Form {
                TextField("Name", text: $name, prompt: Text("e.g. swift-testing"))
                TextField("Description", text: $description, prompt: Text("When should agents use this skill?"))
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .frame(height: 115)

            Text("Creates ~/.agents/skills/\(previewSlug)/SKILL.md")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Create") {
                    if let created = store.createSkill(name: name, description: description) {
                        onCreated(created)
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}
