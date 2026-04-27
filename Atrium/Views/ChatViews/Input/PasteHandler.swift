import SwiftUI
import AppKit

struct PasteHandler: ViewModifier {
    @Bindable var chat: Chat
    @State private var eventMonitor: Any?
    @State private var hostingView: NSView?

    func body(content: Content) -> some View {
        content
            .background(HostingViewFinder(hostingView: $hostingView))
            .onAppear { installMonitor() }
            .onDisappear { removeMonitor() }
            .onChange(of: chat.id) { _, _ in
                installMonitor()
            }
    }

    private func installMonitor() {
        removeMonitor()
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.contains(.command),
                  event.charactersIgnoringModifiers == "v",
                  isViewInKeyWindow() else {
                return event
            }
            return handlePaste() ? nil : event
        }
    }

    private func removeMonitor() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    private func isViewInKeyWindow() -> Bool {
        guard let view = hostingView, let window = view.window else { return false }
        return window == NSApp.keyWindow
    }

    private func handlePaste() -> Bool {
        guard let items = NSPasteboard.general.pasteboardItems else { return false }
        var attachments: [ChatAttachment] = []
        for item in items {
            if let attachment = AttachmentLoader.loadFromPasteboard(item) {
                attachments.append(attachment)
            }
        }
        guard !attachments.isEmpty else { return false }
        chat.pendingAttachments.append(contentsOf: attachments)
        return true
    }
}

private struct HostingViewFinder: NSViewRepresentable {
    @Binding var hostingView: NSView?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { hostingView = view }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

extension View {
    func imagePasteHandler(chat: Chat) -> some View {
        modifier(PasteHandler(chat: chat))
    }
}
