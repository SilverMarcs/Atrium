import SwiftUI

/// A project's scratchpad: drafts put aside, newest first, kept on its host
/// and shared by every client. Choosing one opens it to edit; New Draft
/// opens the same editor empty.
struct ScratchpadSheet: View {
    let item: HostTask
    let composer: TaskComposer
    @Environment(\.dismiss) private var dismiss
    @State private var isAddingDraft = false

    var body: some View {
        NavigationStack {
            Group {
                let drafts = item.scratchpad
                if drafts.isEmpty {
                    ContentUnavailableView("Scratchpad Is Empty", systemImage: "note.text", description: Text(emptyHint))
                } else {
                    List(drafts) { draft in
                        NavigationLink(value: draft.id) {
                            ScratchpadDraftRow(draft: draft, host: item.host)
                        }
                        .contextMenu {
                            Button("Move to Composer", systemImage: "arrow.up.doc") { moveToComposer(draft) }
                            Button("Delete", systemImage: "trash", role: .destructive) { delete(draft) }
                        }
                        .swipeActions(edge: .leading) {
                            Button("Move to Composer", systemImage: "arrow.up.doc") { moveToComposer(draft) }
                                .tint(.accentColor)
                        }
                        .swipeActions {
                            Button("Delete", systemImage: "trash", role: .destructive) { delete(draft) }
                        }
                    }
                    #if os(iOS)
                    .contentMargins(.top, 16, for: .scrollContent)
                    #endif
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Scratchpad")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("New Draft", systemImage: "plus") { isAddingDraft = true }
                }
            }
            .navigationDestination(for: ScratchpadDraft.ID.self) { id in
                ScratchpadDraftEditor(id: id, item: item, composer: composer) { dismiss() }
            }
            .navigationDestination(isPresented: $isAddingDraft) {
                ScratchpadDraftEditor(id: nil, item: item, composer: composer) { dismiss() }
            }
        }
        #if os(macOS)
        .frame(width: 480, height: 420)
        #else
        .presentationDetents([.medium, .large])
        #endif
    }

    private var emptyHint: String {
        #if os(macOS)
        "Press ⌘S to put the draft aside, or select text in a reply and choose Scratchpad."
        #else
        "Select text in the composer or a reply and choose Scratchpad."
        #endif
    }

    private func moveToComposer(_ draft: ScratchpadDraft) {
        composer.restore(draft, from: item)
        dismiss()
    }

    private func delete(_ draft: ScratchpadDraft) {
        item.deleteScratchpadDraft(draft.id)
    }
}

/// One draft opened from the scratchpad: its text to change, its images to
/// look at, and Move to Composer. A new draft starts empty and joins the
/// scratchpad when you leave it with something typed.
private struct ScratchpadDraftEditor: View {
    /// The draft to edit, or nil for a new one.
    let id: ScratchpadDraft.ID?
    let item: HostTask
    let composer: TaskComposer
    let closeSheet: () -> Void
    @Environment(\.dismiss) private var pop
    @State private var text = ""
    @State private var savedText: String?
    @State private var saveTask: Task<Void, Never>?
    @FocusState private var isEditing: Bool

    var body: some View {
        if let id {
            if let draft = item.scratchpad.first(where: { $0.id == id }) {
                editor(imageKeys: draft.imageKeys)
                    .navigationTitle("Draft")
                    .task {
                        text = draft.text
                        savedText = draft.text
                    }
                    .onChange(of: text) { scheduleSave() }
            }
        } else {
            editor(imageKeys: [])
                .navigationTitle("New Draft")
                .task {
                    savedText = ""
                    isEditing = true
                }
        }
    }

    private func editor(imageKeys: [String]) -> some View {
        VStack(spacing: 0) {
            TextEditor(text: $text)
                .focused($isEditing)
                #if os(iOS)
                .contentMargins(.horizontal, 16, for: .scrollContent)
                #else
                .font(.body.monospaced())
                .scrollContentBackground(.hidden)
                .padding(8)
                #endif
            if !imageKeys.isEmpty {
                Divider()
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(imageKeys, id: \.self) { key in
                            ScratchpadImage(host: item.host, key: key, size: 52)
                        }
                    }
                    .padding(12)
                }
                .scrollIndicators(.hidden)
            }
        }
        .toolbarTitleDisplayMode(.inline)
        .onDisappear { Task { await save() } }
        .toolbar {
            ToolbarItem(placement: deletePlacement) {
                Button("Delete", systemImage: "trash", role: .destructive) {
                    saveTask?.cancel()
                    savedText = text
                    if let id { item.deleteScratchpadDraft(id) }
                    pop()
                }
            }
            ToolbarItem(placement: movePlacement) {
                Button("Move to Composer", systemImage: "arrow.up.doc", action: moveToComposer)
                    .disabled(id == nil && !hasText)
                    #if os(iOS)
                    .labelStyle(.titleOnly)
                    #endif
            }
        }
    }

    private var hasText: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func moveToComposer() {
        if let id {
            guard let draft = item.scratchpad.first(where: { $0.id == id }) else { return }
            Task {
                await save()
                composer.restore(draft, from: item)
            }
        } else {
            // A new draft never reached the host: its text goes straight over.
            savedText = text
            composer.restore((text: text, images: []))
        }
        closeSheet()
    }

    private var deletePlacement: ToolbarItemPlacement {
        #if os(iOS)
        .topBarTrailing
        #else
        .destructiveAction
        #endif
    }

    private var movePlacement: ToolbarItemPlacement {
        #if os(iOS)
        .bottomBar
        #else
        .confirmationAction
        #endif
    }

    /// Typing is coalesced so the host isn't updated on every keystroke.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await save()
        }
    }

    private func save() async {
        saveTask?.cancel()
        guard let savedText, text != savedText, let workspaceID = item.task.workspaceID else { return }
        self.savedText = text
        if let id {
            await item.host.perform(.workspace(id: workspaceID, action: .editScratchpadDraft(id: id, text: text)))
        } else if hasText {
            composer.addTextToScratchpad(text, of: item)
        }
    }
}

private struct ScratchpadDraftRow: View {
    let draft: ScratchpadDraft
    let host: HostClient

    var body: some View {
        HStack(spacing: 12) {
            Text(draft.title)
                .lineLimit(2)
                .foregroundStyle(draft.hasText ? .primary : .secondary)
            Spacer(minLength: 0)
            // Up to three thumbnails fanned out.
            ZStack(alignment: .leading) {
                ForEach(Array(draft.imageKeys.prefix(3).enumerated()), id: \.element) { index, key in
                    ScratchpadImage(host: host, key: key, size: 30)
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(.background, lineWidth: 1.5))
                        .offset(x: CGFloat(index) * 14)
                        .zIndex(Double(-index))
                }
            }
            .padding(.trailing, CGFloat(max(min(draft.imageKeys.count, 3) - 1, 0)) * 14)
        }
        .frame(minHeight: 32)
        .padding(.vertical, 2)
    }
}

/// An image of a draft, fetched from its host.
private struct ScratchpadImage: View {
    let host: HostClient
    let key: String
    let size: CGFloat
    @State private var data: Data?
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Group {
            if let data {
                PromptImageThumbnail(data: data, size: size)
            } else {
                RoundedRectangle(cornerRadius: PromptImageThumbnail.cornerRadius * size / 96).fill(.quaternary)
            }
        }
        .frame(width: size, height: size)
        .task(id: key) { data = await host.scratchpadImage(key: key, maxPixelSize: Int(size * displayScale)) }
    }
}

extension HostTask {
    func deleteScratchpadDraft(_ id: ScratchpadDraft.ID) {
        guard let workspaceID = task.workspaceID else { return }
        host.send(.workspace(id: workspaceID, action: .removeScratchpadDraft(id: id)))
    }
}

extension ScratchpadDraft {
    var hasText: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// The text on one line, or what's attached when there's no text.
    var title: String {
        hasText ? text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces) : imageCount
    }

    /// The images, when there's text to title the draft.
    var imageSummary: String? {
        hasText && !imageKeys.isEmpty ? imageCount : nil
    }

    private var imageCount: String {
        imageKeys.count == 1 ? "1 image" : "\(imageKeys.count) images"
    }
}
