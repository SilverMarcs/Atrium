import AppKit
import AtriumProtocol
import SwiftUI

struct RemoteTerminalRepresentable: NSViewRepresentable {
    let frame: WireTerminalFrame
    let acceptsInput: Bool
    let send: (Data) -> Void
    @Environment(\.colorScheme) private var colorScheme

    func makeNSView(context: Context) -> RemoteTerminalViewport {
        RemoteTerminalViewport()
    }

    func updateNSView(_ viewport: RemoteTerminalViewport, context: Context) {
        viewport.terminal.sendInput = acceptsInput ? send : nil
        viewport.update(frame, isDark: colorScheme == .dark)
    }

    static func dismantleNSView(_ viewport: RemoteTerminalViewport, coordinator: ()) {
        viewport.terminal.sendInput = nil
    }
}
