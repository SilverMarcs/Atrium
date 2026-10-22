import SwiftUI

struct GitStashListSheet: View {
    let directoryURL: URL
    @Bindable var state: GitInspectorState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @State private var stashes: [GitStashEntry] = []
    @State private var isLoading = true

    private var snapshot: GitRepositoryStatusSnapshot? { state.currentSnapshot }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if stashes.isEmpty {
                    ContentUnavailableView(
                        "No Stashes",
                        systemImage: "tray",
                        description: Text("You haven't stashed any changes.")
                    )
                } else {
                    List {
                        ForEach(stashes) { entry in
                            stashRow(entry)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                                .onTapGesture { openDiffs(for: entry) }
                                .contextMenu {
                                    applyButton(entry)
                                    dropButton(entry)
                                }
                                .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                    applyButton(entry)
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    dropButton(entry)
                                }
                        }
                    }
                    .listStyle(.inset)
                }
            }
            .navigationTitle("Stashes")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .frame(width: 520, height: 480)
        .task { await load() }
    }

    @ViewBuilder
    private func stashRow(_ entry: GitStashEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.message)
                .font(.body)
                .lineLimit(2)
            HStack(spacing: 6) {
                Text("stash@{\(entry.index)}")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                if let branch = entry.branch {
                    Text("·")
                        .foregroundStyle(.secondary)
                    Text(branch)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let date = entry.date {
                    Text("·")
                        .foregroundStyle(.secondary)
                    Text(date, format: .relative(presentation: .named))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func openDiffs(for entry: GitStashEntry) {
        guard let snapshot else { return }
        openWindow(value: GitCommitDiffSheetItem(
            hash: entry.hash,
            message: entry.message,
            repositoryRootURL: snapshot.repositoryRootURL,
            preloadedFiles: nil,
            stashIndex: entry.index
        ))
        dismiss()
    }

    private func drop(_ entry: GitStashEntry) {
        guard let snapshot else { return }
        Task {
            _ = await state.model.dropStash(index: entry.index, snapshot: snapshot)
            await load()
            await state.refresh(directoryURL: directoryURL)
        }
    }

    private func apply(_ entry: GitStashEntry) {
        guard let snapshot else { return }
        Task {
            await state.model.applyStash(index: entry.index, snapshot: snapshot)
            await state.refresh(directoryURL: directoryURL)
        }
    }

    @ViewBuilder
    private func applyButton(_ entry: GitStashEntry) -> some View {
        Button {
            apply(entry)
        } label: {
            Label("Apply", systemImage: "tray.and.arrow.up")
        }
        .tint(.accentColor)
    }

    @ViewBuilder
    private func dropButton(_ entry: GitStashEntry) -> some View {
        Button(role: .destructive) {
            drop(entry)
        } label: {
            Label("Drop", systemImage: "trash")
        }
    }

    private func load() async {
        guard let snapshot else {
            isLoading = false
            return
        }
        isLoading = stashes.isEmpty
        stashes = await state.model.stashList(snapshot: snapshot)
        isLoading = false
    }
}
