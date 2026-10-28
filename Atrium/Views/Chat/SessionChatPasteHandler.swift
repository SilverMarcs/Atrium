import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SessionChatPasteHandler: ViewModifier {
  @Binding var prompt: String
  @Binding var images: [ComposerImage]
  let isFocused: Bool
  @Environment(AppState.self) private var appState
  @State private var eventMonitor: Any?
  @State private var hostingView = NSView()
  @State private var importError: String?

  func body(content: Content) -> some View {
    content
      .background(SessionChatPasteAnchor(view: hostingView))
      .onAppear(perform: installMonitor)
      .onDisappear(perform: removeMonitor)
      .onChange(of: isFocused) { installMonitor() }
      .onChange(of: appState.selectedThreadID) { installMonitor() }
      .alert(
        "Couldn’t Paste Attachment",
        isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })
      ) {
        Button("OK") { importError = nil }
      } message: {
        Text(importError ?? "")
      }
  }

  private func installMonitor() {
    removeMonitor()
    guard isFocused else { return }
    eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      guard event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command,
        event.charactersIgnoringModifiers?.lowercased() == "v",
        let window = hostingView.window, window == NSApp.keyWindow
      else { return event }
      return handlePaste() ? nil : event
    }
  }

  private func removeMonitor() {
    if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
    eventMonitor = nil
  }

  private func handlePaste() -> Bool {
    let items = (NSPasteboard.general.pasteboardItems ?? []).filter { item in
      if let url = fileURL(from: item) {
        let type = UTType(filenameExtension: url.pathExtension)
        return type?.conforms(to: .image) == true || type?.conforms(to: .text) == true
      }
      return item.types.contains(.png) || item.types.contains(.tiff)
    }
    guard !items.isEmpty else { return false }
    let threadID = appState.selectedThreadID
    let editor = hostingView.window?.firstResponder as? NSTextView
    Task {
      for item in items {
        do {
          if let url = fileURL(from: item), UTType(filenameExtension: url.pathExtension)?.conforms(to: .text) == true {
            let text = try await Self.readText(at: url)
            if appState.selectedThreadID == threadID,
              let editor, editor.window?.firstResponder === editor, editor.string == prompt {
              editor.insertText(text, replacementRange: editor.selectedRange())
            } else {
              prompt += text
            }
          } else {
            guard images.count < 10 else {
              throw IntegrationError(message: "Attach up to 10 images at a time.")
            }
            let image: ComposerImage?
            if let url = fileURL(from: item) {
              image = try await ComposerImage.prepare(contentsOf: url)
            } else if let data = item.data(forType: .png) ?? item.data(forType: .tiff) {
              image = await ComposerImage.prepare(data)
            } else {
              image = nil
            }
            guard let image else {
              throw IntegrationError(message: "This image could not be read.")
            }
            guard images.count < 10 else {
              throw IntegrationError(message: "Attach up to 10 images at a time.")
            }
            images.append(image)
          }
        } catch { importError = error.localizedDescription }
      }
    }
    return true
  }

  private func fileURL(from item: NSPasteboardItem) -> URL? {
    guard let value = item.string(forType: .fileURL), let url = URL(string: value), url.isFileURL else { return nil }
    return url
  }

  @concurrent
  private static func readText(at url: URL) async throws -> String {
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    guard size <= 10 * 1024 * 1024 else {
      throw IntegrationError(message: "Text files must be 10 MB or smaller.")
    }
    var encoding = String.Encoding.utf8
    return try String(contentsOf: url, usedEncoding: &encoding)
  }
}
