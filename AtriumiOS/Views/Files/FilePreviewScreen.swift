import SwiftUI
import UIKit

/// A file on a project's host, read-only: text up to a size cap, or an image.
/// It reloads when the file changes there.
struct FilePreviewScreen: View {
    let host: HostClient
    let workspaceID: UUID
    let path: String
    /// A line to scroll to and mark, as from a search match.
    var line: Int?
    @State private var preview: FilePreview?
    @State private var error: String?

    private var topic: HostTopic { .file(workspaceID: workspaceID, path: path) }

    var body: some View {
        Group {
            switch preview {
            case .text(let text):
                TextPreview(text: text, line: line)
            case .image(let data):
                if let image = UIImage(data: data) {
                    ScrollView([.horizontal, .vertical]) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .containerRelativeFrame([.horizontal])
                    }
                } else {
                    ContentUnavailableView("Preview Not Available", systemImage: "photo")
                }
            case .tooLarge(let bytes):
                ContentUnavailableView(
                    "File Too Large",
                    systemImage: "doc.badge.ellipsis",
                    description: Text("This file is \(bytes.formatted(.byteCount(style: .file))), too large to preview.")
                )
            case .binary:
                ContentUnavailableView("Preview Not Available", systemImage: "doc", description: Text("This file can’t be shown as text."))
            case nil:
                if let error {
                    ContentUnavailableView("Couldn’t Open File", systemImage: "exclamationmark.triangle", description: Text(error))
                } else {
                    ProgressView()
                        .controlSize(.large)
                }
            }
        }
        .navigationTitle((path as NSString).lastPathComponent)
        .toolbarTitleDisplayMode(.inline)
        .task(id: topic) {
            await host.follow(topic)
        }
        .task(id: host.fileRevisions[topic]) {
            await load()
        }
    }

    private func load() async {
        do {
            guard case .preview(let preview) = try await host.files(.read(path: path), in: workspaceID) else {
                throw HostClientError.unexpectedReply
            }
            self.preview = preview
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Text with line numbers, scrolled to a line when one is given.
private struct TextPreview: View {
    let text: String
    let line: Int?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                CodeLinesView(lines: CodeLine.lines(of: text), markedLine: line)
                    .padding(.vertical, 8)
                    .textSelection(.enabled)
            }
            .task(id: line) {
                if let line { proxy.scrollTo(line, anchor: .center) }
            }
        }
    }
}
