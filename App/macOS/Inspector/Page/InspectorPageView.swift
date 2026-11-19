import AtriumClient
import AtriumProtocol
import SwiftUI
import WebKit

/// A page an agent showed, beside the chat at the inspector's width and scrolling
/// on its own.
struct InspectorPageView: View {
    let page: InspectorPage
    let media: ChatMedia
    @State private var isExpanded = false

    var body: some View {
        Group {
            if let model = page.model, model.phase == .loaded {
                WebView(model.webPage)
                    // Pages leave out their own margins; these scroll with the page.
                    .safeAreaPadding([.horizontal, .top])
                    .webViewContentBackground(.hidden)
                    .scrollBounceBehavior(.basedOnSize)
                    .chatPageMenu(model, expand: { isExpanded = true }, download: { page.download($0) })
            } else if page.model?.phase == .unavailable {
                ContentUnavailableView("Page Unavailable", systemImage: "exclamationmark.triangle",
                                       description: Text("Reconnect to the host and try again."))
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .alert("Couldn’t Save Page", isPresented: Binding {
            page.downloader.exportError != nil
        } set: {
            if !$0 { page.downloader.exportError = nil }
        }) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(page.downloader.exportError ?? "")
        }
        .sheet(isPresented: $isExpanded) {
            if let shown = page.page {
                ChatPageSheet(page: shown)
                    .environment(\.chatMedia, media)
            }
        }
    }
}

/// Saves the page into Downloads, under it.
struct PageSaveMenu: View {
    let page: InspectorPage

    var body: some View {
        Menu {
            Button("Save as HTML", systemImage: "chevron.left.forwardslash.chevron.right") { page.download(.html) }
            Button("Save as PNG", systemImage: "photo") { page.download(.png) }
        } label: {
            Label("Save", systemImage: page.downloader.savedFormat == nil ? "square.and.arrow.down" : "checkmark")
                .contentTransition(.symbolEffect(.replace))
        }
        .menuIndicator(.hidden)
        .disabled(!page.isLoaded)
    }
}

/// Switches or saves the page, under it: any other page the chat showed,
/// and the versions an agent showed of this one.
struct PageControls: View {
    let item: HostTask
    let page: InspectorPage
    let shown: ChatPageBlock
    @Environment(AppModel.self) private var app

    var body: some View {
        let pages = ConversationTurns.pageVersions(in: item.host.conversations.displayMessages(for: item.task.id))
        let versions = pages.first { $0.contains { $0.id == shown.id } } ?? [shown]
        let index = versions.firstIndex { $0.id == shown.id } ?? 0
        HStack {
            Menu(shown.page.title) {
                ForEach(pages, id: \.last?.id) { versions in
                    if let latest = versions.last {
                        Button(latest.page.title) { show(latest) }
                    }
                }
            }
            .disabled(pages.count < 2)
            Spacer()
            if versions.count > 1 {
                Text("\(index + 1) of \(versions.count)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                ControlGroup {
                    Button("Older Version", systemImage: "chevron.left") { show(versions[index - 1]) }
                        .disabled(index == 0)
                    Button("Newer Version", systemImage: "chevron.right") { show(versions[index + 1]) }
                        .disabled(index == versions.count - 1)
                }
                .fixedSize()
            }
            PageSaveMenu(page: page)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.glass)
        .controlSize(.large)
        .padding(10)
    }

    private func show(_ block: ChatPageBlock) {
        app.inspectorPages.show(block, for: item.id)
    }
}
