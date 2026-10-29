import AppKit
import SwiftTerm

/// A renderer and input encoder, with no local shell. Host device replies stay
/// on the host; only actual user input is sent through TerminalViewDelegate.
final class RemoteTerminalCanvas: TerminalView, TerminalViewDelegate {
    var sendInput: ((Data) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        terminalDelegate = self
    }

    required init?(coder: NSCoder) { nil }

    nonisolated override func send(source: SwiftTerm.Terminal, data: ArraySlice<UInt8>) {}

    func send(source: TerminalView, data: ArraySlice<UInt8>) { sendInput?(Data(data)) }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
