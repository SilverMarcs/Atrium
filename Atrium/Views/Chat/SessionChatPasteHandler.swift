import AppKit
import SwiftUI

struct SessionChatPasteHandler: ViewModifier {
  let composer: TaskComposer
  let isFocused: Bool
  @Environment(AppModel.self) private var app
  @State private var eventMonitor: Any?
  @State private var hostingView = NSView()

  func body(content: Content) -> some View {
    content
      .background(SessionChatPasteAnchor(view: hostingView))
      .onAppear(perform: installMonitor)
      .onDisappear(perform: removeMonitor)
      .onChange(of: isFocused) { installMonitor() }
      .onChange(of: app.selection) { installMonitor() }
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
        return ComposerPasteContent.supports(url)
      }
      return item.types.contains(.png) || item.types.contains(.tiff)
    }
    guard !items.isEmpty else { return false }
    let threadID = app.selection
    let editor = hostingView.window?.firstResponder as? NSTextView
    Task {
      for item in items {
        do {
          let content: ComposerPasteContent
          if let url = fileURL(from: item) {
            content = try await ComposerPasteContent.load(contentsOf: url)
          } else if let data = item.data(forType: .png) ?? item.data(forType: .tiff) {
            try composer.checkImageSlot()
            content = try await ComposerPasteContent.load(imageData: data)
          } else {
            continue
          }
          switch content {
          case .text(let text):
            if app.selection == threadID,
              let editor, editor.window?.firstResponder === editor, editor.string == composer.draft {
              editor.insertText(text, replacementRange: editor.selectedRange())
            } else {
              composer.draft += text
            }
          case .image(let image):
            try composer.attachPastedImage(image)
          }
        } catch { composer.attachmentError = error.localizedDescription }
      }
    }
    return true
  }

  private func fileURL(from item: NSPasteboardItem) -> URL? {
    guard let value = item.string(forType: .fileURL), let url = URL(string: value), url.isFileURL else { return nil }
    return url
  }
}
