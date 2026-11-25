import AppKit
import QuartzCore

/// A simulator's screen inside its bezel, live, which takes the Mac's mouse,
/// trackpad and keyboard as touches and keys:
/// - click and drag to touch, and drag up from the bottom edge to go home;
/// - hold Option to touch with two fingers mirrored around the middle, to pinch;
/// - scroll and pinch on the trackpad to drag and pinch the screen;
/// - click the side buttons to press them;
/// - once clicked, keys go to the simulator: ⌘V pastes the Mac's clipboard,
///   ⇧⌘H goes home and ⌘← ⌘→ turn the device.
///
/// The screen is the simulator's own framebuffer as the screen layer's
/// contents, redrawn whenever the simulator draws.
final class SimulatorDisplayView: NSView {
    var session: SimulatorSession? {
        didSet {
            guard session !== oldValue else { return }
            releaseInput()
            stopViewing()
            rebuild()
            updateViewing()
            session?.input.prepare()
        }
    }

    var showsBezel = true {
        didSet {
            guard showsBezel != oldValue else { return }
            rebuild()
        }
    }

    var isBooted = false {
        didSet {
            guard isBooted != oldValue else { return }
            updateViewing()
            if isBooted { session?.input.prepare() }
        }
    }

    /// How far the device is turned clockwise, in quarter turns.
    var quarterTurns = 0 {
        didSet {
            guard quarterTurns != oldValue else { return }
            needsLayout = true
        }
    }

    /// The room left around the device.
    static let margin: CGFloat = 12

    private let deviceLayer = CALayer()
    private let screenLayer = CALayer()
    private var buttonLayers: [(button: SimulatorChrome.Button, layer: CALayer)] = []
    /// The device's drawing: its size and where its screen sits.
    private var drawing = CGRect.zero
    private var screenRect = CGRect.zero
    private var scale: CGFloat = 1
    private var viewer: UUID?

    private enum Gesture {
        case touch(pinch: Bool)
        case button(Int)
    }
    private var gesture: Gesture?
    /// A scroll or pinch drag in progress, as fractions of the upright screen.
    private var scrollFinger: CGPoint?
    private var scrollEnd: Task<Void, Never>?
    private var pinch: (center: CGPoint, spread: CGFloat)?
    private var heldKeys: Set<UInt32> = []

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { session != nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        screenLayer.backgroundColor = NSColor.black.cgColor
        screenLayer.contentsGravity = .resize
        screenLayer.masksToBounds = true
        deviceLayer.actions = ["transform": NSNull(), "position": NSNull(), "bounds": NSNull()]
        screenLayer.actions = ["contents": NSNull()]
        layer?.addSublayer(deviceLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Layers

    private func rebuild() {
        deviceLayer.sublayers = nil
        buttonLayers = []
        guard let session else { return }
        let chrome = session.chrome
        let contentsScale = window?.backingScaleFactor ?? 2
        if showsBezel {
            drawing = CGRect(origin: .zero, size: chrome.size)
            screenRect = chrome.screen
            for button in chrome.buttons where !button.onTop {
                addButton(button, scale: contentsScale)
            }
            if let image = chrome.bodyImage {
                let body = CALayer()
                body.frame = chrome.body
                body.contents = image.layerContents(forContentsScale: contentsScale * 2)
                body.contentsGravity = .resize
                deviceLayer.addSublayer(body)
            }
        } else {
            drawing = CGRect(origin: .zero, size: chrome.screen.size)
            screenRect = drawing
        }
        screenLayer.frame = screenRect
        screenLayer.mask = nil
        screenLayer.cornerRadius = 0
        if let mask = chrome.screenMask {
            let maskLayer = CALayer()
            maskLayer.frame = CGRect(origin: .zero, size: screenRect.size)
            maskLayer.contents = mask.layerContents(forContentsScale: contentsScale * 2)
            maskLayer.contentsGravity = .resize
            screenLayer.mask = maskLayer
        } else {
            screenLayer.cornerRadius = chrome.screenCornerRadius
        }
        deviceLayer.addSublayer(screenLayer)
        if showsBezel {
            for button in chrome.buttons where button.onTop {
                addButton(button, scale: contentsScale)
            }
        }
        deviceLayer.bounds = drawing
        needsLayout = true
        showFrame()
    }

    private func addButton(_ button: SimulatorChrome.Button, scale: CGFloat) {
        let layer = CALayer()
        layer.frame = button.frame
        layer.contents = button.image.layerContents(forContentsScale: scale * 2)
        layer.contentsGravity = .resize
        layer.actions = ["contents": NSNull()]
        deviceLayer.addSublayer(layer)
        buttonLayers.append((button, layer))
    }

    override func layout() {
        super.layout()
        guard drawing.width > 0 else { return }
        let turned = quarterTurns % 2 == 0 ? drawing.size : CGSize(width: drawing.height, height: drawing.width)
        let margin = Self.margin
        scale = max(0.05, min((bounds.width - margin * 2) / turned.width, (bounds.height - margin * 2) / turned.height, 1.5))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        deviceLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        // The view is flipped, so a positive angle turns the device clockwise.
        deviceLayer.setAffineTransform(CGAffineTransform(scaleX: scale, y: scale).rotated(by: CGFloat(quarterTurns) * .pi / 2))
        CATransaction.commit()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        rebuild()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { releaseInput() }
        updateViewing()
    }

    override func viewDidHide() {
        super.viewDidHide()
        updateViewing()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        updateViewing()
    }

    // MARK: - Frames

    /// Reads the screen only while it's on screen and booted.
    private func updateViewing() {
        let shouldView = session != nil && isBooted && window != nil && !isHiddenOrHasHiddenAncestor
        if shouldView, viewer == nil, let session {
            viewer = session.screen.addViewer { [weak self] in self?.showFrame() }
        } else if !shouldView {
            stopViewing()
        }
    }

    private func stopViewing() {
        if let viewer, let session { session.screen.removeViewer(viewer) }
        viewer = nil
        screenLayer.contents = nil
    }

    private func showFrame() {
        guard viewer != nil, let surface = session?.screen.surface else {
            if viewer == nil { screenLayer.contents = nil }
            return
        }
        if let current = screenLayer.contents as AnyObject?, current === surface {
            // The same surface with new pixels: Core Animation only rereads it when told.
            screenLayer.perform(NSSelectorFromString("setContentsChanged"))
        } else {
            screenLayer.contents = surface
        }
    }

    // MARK: - Geometry

    /// A point in this view, in the device's own upright drawing.
    private func devicePoint(_ event: NSEvent) -> CGPoint {
        devicePoint(fromView: convert(event.locationInWindow, from: nil))
    }

    private func devicePoint(fromView point: CGPoint) -> CGPoint {
        let angle = CGFloat(quarterTurns) * .pi / 2
        let x = (point.x - bounds.midX) / scale
        let y = (point.y - bounds.midY) / scale
        // Undo the clockwise turn.
        let upright = CGPoint(x: x * cos(angle) + y * sin(angle), y: -x * sin(angle) + y * cos(angle))
        return CGPoint(x: upright.x + drawing.width / 2, y: upright.y + drawing.height / 2)
    }

    /// A point of the drawing as a fraction of the upright screen.
    private func screenFraction(_ point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - screenRect.minX) / screenRect.width, y: (point.y - screenRect.minY) / screenRect.height)
    }

    /// A move in this view as a move in fractions of the upright screen.
    private func screenFractionDelta(dx: CGFloat, dy: CGFloat) -> CGPoint {
        let angle = CGFloat(quarterTurns) * .pi / 2
        let x = dx / scale, y = dy / scale
        let upright = CGPoint(x: x * cos(angle) + y * sin(angle), y: -x * sin(angle) + y * cos(angle))
        return CGPoint(x: upright.x / screenRect.width, y: upright.y / screenRect.height)
    }

    private func edge(at fraction: CGPoint) -> SimulatorInput.Edge {
        guard let session else { return .none }
        let margin: CGFloat = 0.03
        let edge = session.bottomEdge
        switch edge {
        case .bottom: return fraction.y > 1 - margin ? edge : .none
        case .top: return fraction.y < margin ? edge : .none
        case .right: return fraction.x > 1 - margin ? edge : .none
        case .left: return fraction.x < margin ? edge : .none
        case .none: return .none
        }
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let session, isBooted else { return }
        let point = devicePoint(event)
        if showsBezel, let index = buttonLayers.firstIndex(where: { $0.button.frame.contains(point) }) {
            let entry = buttonLayers[index]
            if let down = entry.button.imageDown {
                entry.layer.contents = down.layerContents(forContentsScale: (window?.backingScaleFactor ?? 2) * 2)
            }
            session.input.press(.usage(page: entry.button.usagePage, usage: entry.button.usage), down: true)
            gesture = .button(index)
            return
        }
        guard screenRect.contains(point) else { return }
        let fraction = screenFraction(point)
        let pinch = event.modifierFlags.contains(.option)
        session.input.touch(.began, at: fraction, second: pinch ? mirrored(fraction) : nil, edge: pinch ? .none : edge(at: fraction))
        gesture = .touch(pinch: pinch)
    }

    override func mouseDragged(with event: NSEvent) {
        guard case .touch(let pinch) = gesture, let session else { return }
        let fraction = screenFraction(devicePoint(event))
        session.input.touch(.moved, at: fraction, second: pinch ? mirrored(fraction) : nil)
    }

    override func mouseUp(with event: NSEvent) {
        defer { gesture = nil }
        guard let session else { return }
        switch gesture {
        case .touch(let pinch):
            let fraction = screenFraction(devicePoint(event))
            session.input.touch(.ended, at: fraction, second: pinch ? mirrored(fraction) : nil)
        case .button(let index):
            let entry = buttonLayers[index]
            entry.layer.contents = entry.button.image.layerContents(forContentsScale: (window?.backingScaleFactor ?? 2) * 2)
            session.input.press(.usage(page: entry.button.usagePage, usage: entry.button.usage), down: false)
        case nil:
            break
        }
    }

    private func mirrored(_ fraction: CGPoint) -> CGPoint {
        CGPoint(x: 1 - fraction.x, y: 1 - fraction.y)
    }

    /// Scrolling drags a finger across the screen from under the pointer,
    /// lifting it once the scroll ends, so iOS flings as it would after a swipe.
    override func scrollWheel(with event: NSEvent) {
        guard let session, isBooted, gesture == nil else { return }
        let start = devicePoint(event)
        if event.phase == .began || (scrollFinger == nil && event.momentumPhase.isEmpty) {
            guard screenRect.contains(start) else { return }
            endScroll()
            let fraction = screenFraction(start)
            scrollFinger = fraction
            session.input.touch(.began, at: fraction)
        }
        guard var finger = scrollFinger else { return }
        // Momentum after the fingers leave is iOS's to add.
        guard event.momentumPhase.isEmpty else { return }
        var dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
        if !event.hasPreciseScrollingDeltas { dx *= 12; dy *= 12 }
        // The finger follows the content: with natural scrolling the deltas already do.
        if !event.isDirectionInvertedFromDevice { dx = -dx; dy = -dy }
        let delta = screenFractionDelta(dx: dx, dy: dy)
        finger = CGPoint(x: min(max(finger.x + delta.x, 0.02), 0.98), y: min(max(finger.y + delta.y, 0.02), 0.98))
        scrollFinger = finger
        session.input.touch(.moved, at: finger)
        if event.phase == .ended || event.phase == .cancelled {
            endScroll()
        } else {
            // A mouse wheel has no phases; its drag ends when the wheel stops.
            scrollEnd?.cancel()
            scrollEnd = Task { [weak self] in
                guard (try? await Task.sleep(for: .milliseconds(event.phase.isEmpty ? 150 : 400))) != nil else { return }
                self?.endScroll()
            }
        }
    }

    private func endScroll() {
        scrollEnd?.cancel()
        scrollEnd = nil
        guard let finger = scrollFinger else { return }
        scrollFinger = nil
        session?.input.touch(.ended, at: finger)
    }

    /// Pinching on the trackpad spreads two fingers around the pointer.
    override func magnify(with event: NSEvent) {
        guard let session, isBooted, gesture == nil else { return }
        switch event.phase {
        case .began:
            let point = devicePoint(event)
            guard screenRect.contains(point) else { return }
            pinch = (screenFraction(point), 0.08)
            if let pinch { session.input.touch(.began, at: finger(pinch, -1), second: finger(pinch, 1)) }
        case .changed:
            guard var current = pinch else { return }
            current.spread = min(max(current.spread * (1 + event.magnification), 0.01), 0.45)
            pinch = current
            session.input.touch(.moved, at: finger(current, -1), second: finger(current, 1))
        default:
            guard let current = pinch else { return }
            pinch = nil
            session.input.touch(.ended, at: finger(current, -1), second: finger(current, 1))
        }
    }

    private func finger(_ pinch: (center: CGPoint, spread: CGFloat), _ side: CGFloat) -> CGPoint {
        CGPoint(x: pinch.center.x + side * pinch.spread, y: pinch.center.y)
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        guard let session, isBooted else { return super.keyDown(with: event) }
        // iOS repeats a held key itself.
        guard !event.isARepeat, let usage = SimulatorKeys.usage(forMacKey: event.keyCode) else { return }
        heldKeys.insert(usage)
        session.input.key(usage, down: true)
    }

    override func keyUp(with event: NSEvent) {
        guard let session, let usage = SimulatorKeys.usage(forMacKey: event.keyCode) else { return }
        heldKeys.remove(usage)
        session.input.key(usage, down: false)
    }

    override func flagsChanged(with event: NSEvent) {
        guard let session, isBooted, let usage = SimulatorKeys.usage(forMacKey: event.keyCode) else { return }
        if event.keyCode == 0x39 {
            // Caps Lock reports its state, not the key: press and release it.
            session.input.key(usage, down: true)
            session.input.key(usage, down: false)
            return
        }
        let flag: NSEvent.ModifierFlags = switch event.keyCode {
        case 0x37, 0x36: .command
        case 0x38, 0x3C: .shift
        case 0x3A, 0x3D: .option
        default: .control
        }
        let down = event.modifierFlags.contains(flag) && !heldKeys.contains(usage)
        if down { heldKeys.insert(usage) } else { heldKeys.remove(usage) }
        session.input.key(usage, down: down)
    }

    /// ⌘ shortcuts the simulator handles, rather than Atrium's menus.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, let session, isBooted,
              event.type == .keyDown, event.modifierFlags.contains(.command) else { return super.performKeyEquivalent(with: event) }
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let shift = event.modifierFlags.contains(.shift)
        switch (key, event.keyCode) {
        case ("h", _) where shift:
            session.input.press(.home)
            return true
        case (_, 0x7B):
            session.rotate(clockwise: false)
            return true
        case (_, 0x7C):
            session.rotate(clockwise: true)
            return true
        case ("v", _):
            // ⌘ is already down in the simulator; the V goes once its clipboard has the text.
            Task {
                await session.pasteMacClipboard()
                session.input.key(SimulatorKeys.v, down: true)
                session.input.key(SimulatorKeys.v, down: false)
            }
            return true
        case ("a", _), ("c", _), ("x", _), ("z", _), ("f", _), ("b", _), ("i", _), ("u", _), (_, 0x24), (_, 0x33), (_, 0x7D), (_, 0x7E):
            if let usage = SimulatorKeys.usage(forMacKey: event.keyCode) {
                session.input.key(usage, down: true)
                session.input.key(usage, down: false)
            }
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }

    override func resignFirstResponder() -> Bool {
        releaseInput()
        return super.resignFirstResponder()
    }

    /// Lets go of every key, finger and button, so none stays down in the simulator.
    private func releaseInput() {
        guard let session else { return }
        for usage in heldKeys { session.input.key(usage, down: false) }
        heldKeys = []
        endScroll()
        if let current = pinch {
            pinch = nil
            session.input.touch(.ended, at: finger(current, -1), second: finger(current, 1))
        }
        if case .button(let index) = gesture, index < buttonLayers.count {
            let button = buttonLayers[index].button
            session.input.press(.usage(page: button.usagePage, usage: button.usage), down: false)
        }
        gesture = nil
    }
}
