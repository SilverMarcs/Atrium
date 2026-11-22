import AtriumClient
import AtriumProtocol
import SwiftUI

/// A project's scratchpad: drafts put aside, newest first, kept on its host
/// and shared by every client. Choosing one opens it to edit.
struct ScratchpadSheet: View {
    let item: HostTask
    let composer: TaskComposer
    @Environment(\.dismiss) private var dismiss

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
            .navigationTitle("Scratchpad")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                Button(role: .close) { dismiss() }
            }
            .navigationDestination(for: ScratchpadDraft.ID.self) { id in
                ScratchpadDraftEditor(id: id, item: item, composer: composer) { dismiss() }
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
        "Press ⌘S to put the draft aside."
        #else
        "Select text in the composer and choose Add to Scratchpad."
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
/// look at, and Move to Composer.
private struct ScratchpadDraftEditor: View {
    let id: ScratchpadDraft.ID
    let item: HostTask
    let composer: TaskComposer
    let closeSheet: () -> Void
    @Environment(\.dismiss) private var pop
    @State private var text = ""
    @State private var savedText: String?
    @State private var saveTask: Task<Void, Never>?

    var body: some View {
        if let draft = item.scratchpad.first(where: { $0.id == id }) {
            VStack(spacing: 0) {
                TextEditor(text: $text)
                    #if os(iOS)
                    .contentMargins(.horizontal, 16, for: .scrollContent)
                    #else
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    #endif
                if !draft.imageKeys.isEmpty {
                    Divider()
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(draft.imageKeys, id: \.self) { key in
                                ScratchpadImage(host: item.host, key: key, size: 52)
                            }
                        }
                        .padding(12)
                    }
                    .scrollIndicators(.hidden)
                }
            }
            .navigationTitle("Draft")
            .toolbarTitleDisplayMode(.inline)
            .task {
                text = draft.text
                savedText = draft.text
            }
            .onChange(of: text) { scheduleSave() }
            .onDisappear { Task { await save() } }
            .toolbar {
                ToolbarItem(placement: deletePlacement) {
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        saveTask?.cancel()
                        savedText = text
                        item.deleteScratchpadDraft(id)
                        pop()
                    }
                }
                ToolbarItem(placement: movePlacement) {
                    Button("Move to Composer", systemImage: "arrow.up.doc") {
                        Task {
                            await save()
                            composer.restore(draft, from: item)
                        }
                        closeSheet()
                    }
                    #if os(iOS)
                    .labelStyle(.titleOnly)
                    #endif
                }
            }
        }
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
        await item.host.perform(.workspace(id: workspaceID, action: .editScratchpadDraft(id: id, text: text)))
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
