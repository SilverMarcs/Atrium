import AppKit
import SwiftUI
import UniformTypeIdentifiers

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
      return imageType(of: item) != nil
    }
    guard !items.isEmpty else { return false }
    let threadID = app.selection
    let editor = hostingView.window?.firstResponder as? NSTextView
    Task {
      for item in items {
        do {
          let content: ComposerPasteContent
          if let url = fileURL(from: item) {
            do {
              content = try await ComposerPasteContent.load(contentsOf: url)
            } catch {
              // Spotlight's clipboard history pastes its cached copy of the
              // file, which only Full Disk Access can read, alongside the
              // image itself.
              guard let data = imageData(of: item) else { throw error }
              try composer.checkImageSlot()
              content = try await ComposerPasteContent.load(imageData: data)
            }
          } else if let data = imageData(of: item) {
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

  private func imageType(of item: NSPasteboardItem) -> NSPasteboard.PasteboardType? {
    item.availableType(from: ComposerPasteContent.imageTypes.map { NSPasteboard.PasteboardType($0.identifier) })
  }

  private func imageData(of item: NSPasteboardItem) -> Data? {
    imageType(of: item).flatMap(item.data(forType:))
  }

  private func fileURL(from item: NSPasteboardItem) -> URL? {
    guard let value = item.string(forType: .fileURL), let url = URL(string: value), url.isFileURL else { return nil }
    return url
  }
}
