import SwiftUI
import WebKit

/// A page an agent showed, in the sheet under its chat: as wide as the chat
/// at most, scrolling on its own. Its title picks the chat's other pages and
/// their versions.
struct PageSheetPanel: View {
    /// The chat that showed the page.
    let item: HostTask
    let shown: ChatPageBlock
    @Environment(EditorPanel.self) private var panel
    @Environment(\.openURL) private var openURL
    @State private var page = SheetPage()
    @State private var isExpanded = false

    private var media: ChatMedia {
        ChatMedia(host: item.host, taskID: item.task.id, directory: item.task.path)
    }

    var body: some View {
        let pages = ConversationTurns.pageVersions(in: item.host.conversations.displayMessages(for: item.task.id))
        PanelLayout {
            Image(systemName: "doc.richtext")
                .foregroundStyle(.secondary)
            if pages.count > 1 || pages.contains(where: { $0.count > 1 }) {
                Menu {
                    PagePickerItems(pages: pages, shown: shown) { panel.openPage($0, in: item.id) }
                } label: {
                    title
                }
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .fixedSize()
                .help("Show Another Page")
            } else {
                title
            }
        } actions: {
            PageSaveMenu(page: page)
        } content: {
            pageContent
        }
        .buttonStyle(.borderless)
        .alert("Couldn’t Save Page", isPresented: Binding {
            page.downloader.exportError != nil
        } set: {
            if !$0 { page.downloader.exportError = nil }
        }) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(page.downloader.exportError ?? "")
        }
        .task(id: shown.id) {
            await page.load(shown.page, media: media, openURL: openURL)
        }
        .sheet(isPresented: $isExpanded) {
            ChatPageSheet(page: shown.page)
                .environment(\.chatMedia, media)
        }
    }

    private var title: some View {
        Text(shown.page.title)
            .font(.subheadline.weight(.medium))
            .lineLimit(1)
    }

    @ViewBuilder
    private var pageContent: some View {
        Group {
            if let model = page.model, model.phase == .loaded {
                WebView(model.webPage)
                    // Pages leave out their own margins; these scroll with the page.
                    .safeAreaPadding(.horizontal, 16)
                    .safeAreaPadding(.vertical, 12)
                    .webViewContentBackground(.hidden)
                    .scrollBounceBehavior(.basedOnSize)
                    .chatPageMenu(model, expand: { isExpanded = true }, download: { page.download($0) })
                    // As wide as the chat above it, so a page reads at one measure.
                    .frame(maxWidth: SessionChatLayout.maximumWidth)
            } else if page.model?.phase == .unavailable {
                ContentUnavailableView("Page Unavailable", systemImage: "exclamationmark.triangle",
                                       description: Text("Reconnect to the host and try again."))
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The chat's pages, for the title's menu: a page an agent revised opens a
/// submenu of its versions, newest first; the one shown has a checkmark.
private struct PagePickerItems: View {
    let pages: [[ChatPageBlock]]
    let shown: ChatPageBlock
    let open: (ChatPageBlock) -> Void

    var body: some View {
        ForEach(pages, id: \.last?.id) { versions in
            if let latest = versions.last {
                if versions.count > 1 {
                    Menu {
                        ForEach(Array(versions.enumerated().reversed()), id: \.element.id) { index, version in
                            item(index == versions.count - 1 ? "Latest" : "Version \(index + 1)", version)
                        }
                    } label: {
                        if versions.contains(where: { $0.id == shown.id }) { Image(systemName: "checkmark") }
                        Text(latest.page.title)
                    }
                } else {
                    item(latest.page.title, latest)
                }
            }
        }
    }

    private func item(_ title: String, _ block: ChatPageBlock) -> some View {
        Toggle(title, isOn: Binding(get: { block.id == shown.id }, set: { _ in open(block) }))
    }
}

/// Saves the page into Downloads.
private struct PageSaveMenu: View {
    let page: SheetPage

    var body: some View {
        Menu {
            Button("Save as HTML", systemImage: "chevron.left.forwardslash.chevron.right") { page.download(.html) }
            Button("Save as PNG", systemImage: "photo") { page.download(.png) }
        } label: {
            Label("Save", systemImage: page.downloader.savedFormat == nil ? "square.and.arrow.down" : "checkmark")
                .contentTransition(.symbolEffect(.replace))
        }
        .labelStyle(.iconOnly)
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(!page.isLoaded)
        .help("Save Page")
    }
}
