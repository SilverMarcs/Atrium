import AtriumClient
import AtriumProtocol
import SwiftUI
import WebKit

/// A page an agent showed, inline at the reply's width and as tall as its
/// content, so the timeline scrolls past it rather than into it. It loads
/// only while on screen; a page taller than the frame allows scrolls inside.
struct ChatPageFrame: View {
    let page: TranscriptPage
    @Environment(HostClient.self) private var host: HostClient?
    @Environment(\.openURL) private var openURL
    @State private var model: ChatPageModel?
    @State private var isVisible = false
    /// The height the page last measured, kept while it's unloaded off screen.
    @State private var measuredHeight: CGFloat?
    @State private var isExpanded = false
    @State private var isHovering = false
    /// The format just saved, shown with a checkmark for a moment.
    @State private var savedFormat: ChatPageExport.Format?
    /// A file waiting for the person to choose where it goes.
    @State private var pendingExport: ChatPageExport?
    @State private var exportError: String?

    private static let minimumHeight: CGFloat = 80
    private static let maximumHeight: CGFloat = 2000

    var body: some View {
        let contentHeight = model?.contentHeight ?? measuredHeight
        let fits = (contentHeight ?? 0) <= Self.maximumHeight
        ZStack(alignment: .topTrailing) {
            if let model, model.phase == .loaded {
                WebView(model.webPage)
                    .webViewContentBackground(.hidden)
                    .scrollBounceBehavior(.basedOnSize)
                    .scrollDisabled(fits)
                    .opacity(model.contentHeight == nil ? 0 : 1)
            }
            if model?.phase == .unavailable {
                Label("\(page.title) is unavailable", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model?.contentHeight == nil {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if showsControls {
                HStack(spacing: 6) {
                    ChatPageControl(title: "Download HTML", systemImage: savedFormat == .html ? "checkmark" : "chevron.left.forwardslash.chevron.right") {
                        download(.html)
                    }
                    ChatPageControl(title: "Download PNG", systemImage: savedFormat == .png ? "checkmark" : "photo") {
                        download(.png)
                    }
                    ChatPageControl(title: "Open \(page.title)", systemImage: "arrow.up.left.and.arrow.down.right") {
                        isExpanded = true
                    }
                }
                .padding(8)
            }
        }
        .frame(height: min(max(contentHeight ?? CGFloat(page.height ?? 240), Self.minimumHeight), Self.maximumHeight))
        .frame(maxWidth: .infinity)
        #if os(macOS)
        .background(ScrollWheelPassthrough(isEnabled: fits))
        #endif
        .onHover { isHovering = $0 }
        .onScrollVisibilityChange(threshold: 0.01) { isVisible = $0 }
        .task(id: isVisible) {
            if isVisible {
                guard model == nil else { return }
                let model = ChatPageModel(openURL: openURL)
                self.model = model
                await model.load(page, from: host)
            } else if let model {
                // Web content is heavy; a reply's pages can be many screens up.
                measuredHeight = model.contentHeight ?? measuredHeight
                self.model = nil
            }
        }
        .sheet(isPresented: $isExpanded) {
            ChatPageSheet(page: page)
        }
        .fileExporter(
            isPresented: Binding { pendingExport != nil } set: { if !$0 { pendingExport = nil } },
            item: pendingExport,
            contentTypes: pendingExport.map { [$0.format.type] } ?? [],
            defaultFilename: pendingExport?.filename
        ) { _ in }
        .alert("Couldn’t Save Page", isPresented: Binding { exportError != nil } set: { if !$0 { exportError = nil } }) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportError ?? "")
        }
    }

    /// Saves straight into Downloads on Mac, where a browser would; elsewhere
    /// the person picks a place in Files.
    private func download(_ format: ChatPageExport.Format) {
        guard let model else { return }
        Task {
            do {
                let file = try await model.export(format, title: page.title)
                #if os(macOS)
                _ = try file.saveToDownloads()
                savedFormat = format
                try? await Task.sleep(for: .seconds(2))
                if savedFormat == format { savedFormat = nil }
                #else
                pendingExport = file
                #endif
            } catch {
                exportError = error.localizedDescription
            }
        }
    }

    private var showsControls: Bool {
        guard model?.phase == .loaded else { return false }
        #if os(macOS)
        return isHovering
        #else
        return true
        #endif
    }
}
