import SwiftUI

struct DetachedEditorView: View {
    let content: EditorPanelContent
    @State private var editorPanel = EditorPanel()
    @State private var showingInfo = false
    @AppStorage(EditorFontSize.key) private var editorFontSize: Double = EditorFontSize.default

    private var fileURL: URL {
        switch content {
        case .file(let url): url
        case .diff(let ref): ref.fileURL
        }
    }

    private var directoryURL: URL {
        switch content {
        case .file(let url):
            url.deletingLastPathComponent()
        case .diff(let ref):
            ref.repositoryRootURL
        }
    }

    private var title: String {
        fileURL.lastPathComponent
    }

    var body: some View {
        Group {
            switch content {
            case .file(let url):
                FileEditorPanel(fileURL: url, directoryURL: directoryURL)
            case .diff(let ref):
                DiffPanel(reference: ref)
            }
        }
        .environment(editorPanel)
        .environment(\.isDetachedEditor, true)
        .environment(\.editorFontSize, CGFloat(editorFontSize))
        .onAppear {
            editorPanel.content = content
            editorPanel.isOpen = true
        }
        .navigationTitle(title)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingInfo.toggle()
                } label: {
                    Image(systemName: "info")
                }
                .popover(isPresented: $showingInfo) {
                    InfoPopover(content: content, fileURL: fileURL, directoryURL: directoryURL)
                }
            }
        }
    }
}
