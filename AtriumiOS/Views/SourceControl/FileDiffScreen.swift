import SwiftUI

/// Per-file diff viewer. Splits the raw `git diff` output into hunks, then
/// paints `+` lines green, `-` lines red, and hunk headers in the accent
/// color. No syntax highlighting, no line wrapping — content scrolls
/// horizontally so wide source lines stay readable on phones.
struct FileDiffScreen: View {
    @Environment(CompanionClient.self) private var client
    let workspaceId: UUID
    let path: String
    /// "staged" or "unstaged".
    let stage: String
    let name: String

    private var diffText: String? {
        client.gitFileDiff(path: path, stage: stage)
    }

    var body: some View {
        Group {
            if let text = diffText {
                if text.isEmpty {
                    ContentUnavailableView("No Changes", systemImage: "doc.plaintext")
                } else {
                    let hunks = DiffParser.parse(text)
                    ScrollView {
                        if !hunks.isEmpty {
                            VStack(alignment: .leading, spacing: 16) {
                                ForEach(hunks) { hunk in
                                    hunkView(hunk)
                                }
                            }
                            .padding(.vertical, 8)
                        } else {
                            // Status string from the host (e.g. "No diff
                            // available.") — show it raw rather than
                            // collapsing to a generic empty state.
                            Text(text)
                                .font(.system(.footnote, design: .monospaced))
                                .padding(8)
                        }
                    }
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(name)
        .toolbarTitleDisplayMode(.inline)
        .task(id: path + "|" + stage) {
            client.gitRequestFileDiff(workspaceId: workspaceId, path: path, stage: stage)
        }
    }

    @ViewBuilder
    private func hunkView(_ hunk: DiffHunk) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(hunk.header)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(.tint)
                .padding(.horizontal, 8)
            // Per-hunk horizontal scroll so wide lines don't force the
            // outer (vertical) scroll view to scroll sideways. The inner
            // VStack uses fixedSize so it sizes to its widest child and
            // the per-line `maxWidth: .infinity` then expands every line
            // to that width — making the red/green backgrounds span the
            // full row instead of just the text.
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(hunk.lines) { line in
                        Text(DiffSyntaxHighlighter.highlight(line.content))
                            .font(.system(.footnote, design: .monospaced))
                            .lineLimit(1)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(line.kind.background)
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
            }
        }
    }
}

// MARK: - Diff Parsing

private struct DiffHunk: Identifiable {
    let id = UUID()
    let header: String
    let lines: [DiffLine]
}

private struct DiffLine: Identifiable {
    let id = UUID()
    let kind: Kind
    let content: String

    enum Kind {
        case added, removed, context

        var background: Color {
            switch self {
            case .added: .green.opacity(0.20)
            case .removed: .red.opacity(0.20)
            case .context: .clear
            }
        }
    }
}

private enum DiffParser {
    static func parse(_ raw: String) -> [DiffHunk] {
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var hunks: [DiffHunk] = []
        var index = 0

        // Skip file-level headers (everything before the first hunk).
        while index < lines.count && !lines[index].hasPrefix("@@") {
            index += 1
        }

        while index < lines.count {
            let line = lines[index]
            guard line.hasPrefix("@@") else { index += 1; continue }
            let header = line
            index += 1

            var hunkLines: [DiffLine] = []
            while index < lines.count
                && !lines[index].hasPrefix("@@")
                && !lines[index].hasPrefix("diff ") {
                let l = lines[index]
                index += 1
                if l.hasPrefix("\\") { continue } // "\ No newline at end of file"
                if l.hasPrefix("+") {
                    hunkLines.append(DiffLine(kind: .added, content: String(l.dropFirst())))
                } else if l.hasPrefix("-") {
                    hunkLines.append(DiffLine(kind: .removed, content: String(l.dropFirst())))
                } else if l.hasPrefix(" ") {
                    hunkLines.append(DiffLine(kind: .context, content: String(l.dropFirst())))
                } else if !l.isEmpty {
                    hunkLines.append(DiffLine(kind: .context, content: l))
                }
            }
            hunks.append(DiffHunk(header: header, lines: hunkLines))
        }
        return hunks
    }
}
