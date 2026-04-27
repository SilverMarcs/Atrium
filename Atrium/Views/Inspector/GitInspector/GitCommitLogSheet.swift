import AppKit
import SwiftUI

struct GitCommitLogSheet: View {
    @Bindable var state: GitInspectorState
    @State private var entries: [GitLogEntry] = []
    @State private var isLoading = true

    private var snapshot: GitRepositoryStatusSnapshot? { state.currentSnapshot }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if entries.isEmpty {
                    ContentUnavailableView(
                        "No Commits",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("This branch has no commit history yet.")
                    )
                } else {
                    List(entries) { entry in
                        commitRow(entry)
                            .listRowSeparator(.visible)
                    }
                    .listStyle(.inset)
                }
            }
            .navigationTitle("Commit Log")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        state.showCommitLogSheet = false
                    }
                }
            }
        }
        .frame(width: 520, height: 480)
        .task {
            await load()
        }
    }

    @ViewBuilder
    private func commitRow(_ entry: GitLogEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.subject)
                .font(.body)
                .lineLimit(2)
            HStack(spacing: 6) {
                Text(entry.shortHash)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Text("·")
                    .foregroundStyle(.secondary)
                Text(entry.author)
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
        .contextMenu {
            Button("Copy Hash") {
                copyToClipboard(entry.hash)
            }
            Button("Copy Short Hash") {
                copyToClipboard(entry.shortHash)
            }
            Button("Copy Subject") {
                copyToClipboard(entry.subject)
            }
        }
    }

    private func load() async {
        guard let snapshot else {
            isLoading = false
            return
        }
        isLoading = true
        let result = await state.model.commitLog(snapshot: snapshot)
        entries = result
        isLoading = false
    }

    private func copyToClipboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}
