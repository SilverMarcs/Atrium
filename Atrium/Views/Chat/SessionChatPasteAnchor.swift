import AppKit
import SwiftUI

struct SessionChatPasteAnchor: NSViewRepresentable {
  let view: NSView

  func makeNSView(context: Context) -> NSView { view }

  func updateNSView(_ nsView: NSView, context: Context) {}
}
