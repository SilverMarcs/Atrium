import AVFoundation
import AppKit
@preconcurrency import WebRTC

/// Shows a preview's video and turns clicks, drags and typing into the
/// preview's input: a click is a tap, a drag a swipe, and once clicked it
/// takes the keyboard.
final class RemotePreviewVideoView: NSView, RTCVideoViewDelegate {
    var send: ((LivePreviewInput) -> Void)?
    var sizeChanged: ((CGSize) -> Void)?
    var track: RTCVideoTrack? {
        didSet {
            guard track !== oldValue else { return }
            oldValue?.remove(video)
            track?.add(video)
        }
    }

    var cornerRadius: CGFloat = 0 {
        didSet { layer?.cornerRadius = cornerRadius }
    }

    private let video = RTCMTLNSVideoView(frame: .zero)
    private var videoSize: CGSize?
    private var dragStart: CGPoint?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        video.delegate = self
        video.autoresizingMask = [.width, .height]
        video.frame = bounds
        addSubview(video)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    // The video view would otherwise take the clicks.
    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        dragStart = convert(event.locationInWindow, from: nil)
    }

    override func mouseUp(with event: NSEvent) {
        guard let start = dragStart else { return }
        dragStart = nil
        let end = convert(event.locationInWindow, from: nil)
        // The video keeps its shape inside the view.
        let rect = videoSize.map { AVMakeRect(aspectRatio: $0, insideRect: bounds) } ?? bounds
        if let input = LivePreviewInput.drag(from: start, to: end, in: rect) { send?(input) }
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) {
            if event.charactersIgnoringModifiers == "v", let text = NSPasteboard.general.string(forType: .string),
               !text.isEmpty, text.utf8.count <= LivePreviewInput.maxTextBytes {
                send?(.text(text))
            } else {
                super.keyDown(with: event)
            }
            return
        }
        switch event.keyCode {
        case 36, 76: send?(.key(.enter))
        case 51: send?(.key(.backspace))
        default:
            // Typed characters only; arrows and function keys have none worth sending.
            guard let text = event.characters, !text.isEmpty,
                  text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && $0.value < 0xF700 })
            else { return super.keyDown(with: event) }
            send?(.text(text))
        }
    }

    nonisolated func videoView(_ videoView: any RTCVideoRenderer, didChangeVideoSize size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        Task { @MainActor [weak self] in
            self?.videoSize = size
            self?.sizeChanged?(size)
        }
    }
}
