import AppKit
import AtriumClient
import QuartzCore
import SwiftUI

/// Flies a just-sent prompt from the composer to its place in the timeline as
/// a Core Animation layer above the window, and slides the conversation up to
/// make room the same way.
///
/// The render server runs both animations, so they keep their frames while
/// the main thread is busy with what a send sets off: the timeline taking the
/// prompt, the host starting the agent, task and transcript updates, the
/// sidebar and inspector. SwiftUI animations, and `TimelineView` clocks, step
/// on the main thread and lose frames to all of it.
///
/// The real bubble stays hidden under its copy until the copy lands, so the
/// timeline itself never animates.
@MainActor
@Observable
final class PromptFlights: PromptSendAnimating {
  /// Timeline rows whose bubble waits under a flying copy.
  private(set) var hidden: Set<String> = []

  @ObservationIgnored var sourceFrame: (() -> CGRect?)?
  /// The chat's text size, for the copy.
  @ObservationIgnored var fontSize: CGFloat = 13
  @ObservationIgnored var reduceMotion = false

  /// The timeline's scroll view, whose content slides on the render server.
  @ObservationIgnored weak var scrollView: NSScrollView?
  /// How wide the timeline's rows are, which sizes the copy before its row lays out.
  @ObservationIgnored var rowWidth: CGFloat = 0
  @ObservationIgnored private var flights: [String: Flight] = [:]
  @ObservationIgnored private weak var overlay: FlightOverlayView?
  /// The timeline as it was just before the latest send.
  @ObservationIgnored private var snapshot: TimelineSnapshot?
  /// Where rows that can fly in were last laid out.
  @ObservationIgnored private var laidOut: [String: CGRect] = [:]
  /// When the latest prompt was sent, so the scroll that follows it slides.
  @ObservationIgnored private var sentAt: CFTimeInterval = 0

  /// Matches the spring the bubble flew with before (response 0.36, damping 0.8).
  static let response: CGFloat = 0.36
  static let bounce: CGFloat = 0.2
  /// Leading space a prompt bubble leaves in its row.
  static let bubbleInset: CGFloat = 160

  private final class Flight {
    let source: CGRect
    let bubble: PromptBubbleCopy
    let layer = CALayer()
    var destination: CGRect?
    var isLaunching = false
    var isFlying = false
    var expiry: Task<Void, Never>?

    init(source: CGRect, bubble: PromptBubbleCopy) {
      self.source = source
      self.bubble = bubble
    }
  }

  /// Whether a prompt was just sent, so the scroll that makes room for it
  /// jumps and slides on the render server.
  var isSending: Bool { CACurrentMediaTime() - sentAt < 0.5 }

  /// Called before the prompt reaches the timeline, which can lay out its row
  /// and scroll for it before the composer hands over its text.
  func prepareSend() {
    laidOut.removeAll()
    sentAt = reduceMotion ? 0 : CACurrentMediaTime()
    snapshot = reduceMotion ? nil : snapshotTimeline()
  }

  func cancelSend() {
    sentAt = 0
    snapshot = nil
  }

  func begin(_ promptID: PendingPrompt.ID, text: String, from frame: CGRect?) {
    guard !text.isEmpty, !reduceMotion else { return }
    begin("pending-\(promptID.uuidString)", bubble: PromptBubbleCopy(text: text, fontSize: fontSize), from: frame)
  }

  /// Shows a copy of the prompt's bubble over the composer at once, before the
  /// timeline has laid out its row, and hides the row's own bubble.
  func begin(_ rowID: String, bubble: PromptBubbleCopy, from source: CGRect?) {
    guard let source, source.width > 0, let overlay = overlayView(),
          let image = render(bubble, width: rowWidth - Self.bubbleInset, in: overlay) else { return }
    let flight = Flight(source: source, bubble: bubble)
    flight.layer.contents = image.image
    flight.layer.contentsScale = image.scale
    flight.layer.bounds = CGRect(origin: .zero, size: image.size)
    flight.layer.position = CGPoint(x: source.midX, y: source.midY)
    flight.layer.transform = CATransform3DMakeScale(0.9, 0.9, 1)
    without { overlay.layer?.addSublayer(flight.layer) }
    flights[rowID] = flight
    var transaction = Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction) { _ = hidden.insert(rowID) }
    // A row that never lays out shows anyway.
    flight.expiry = Task { [weak self] in
      try? await Task.sleep(for: .seconds(2))
      guard !Task.isCancelled else { return }
      self?.land(rowID)
    }
    // The row may have laid out before the composer handed the prompt over.
    if let frame = laidOut[rowID] { noteDestination(rowID, frame: frame) }
  }

  /// Where the row's bubble is, in window coordinates, each time it moves.
  func noteDestination(_ rowID: String, frame: CGRect) {
    guard isSending || flights[rowID] != nil else { return }
    laidOut[rowID] = frame
    guard let flight = flights[rowID], frame.width > 0 else { return }
    let previous = flight.destination
    flight.destination = frame
    if flight.isFlying, let previous, previous != frame {
      retarget(flight, by: CGPoint(x: frame.midX - previous.midX, y: frame.midY - previous.midY))
      return
    }
    guard !flight.isLaunching else { return }
    flight.isLaunching = true
    // The scroll that makes room for the row lands in the same update or the
    // next; fly to where the row settles.
    Task { [weak self] in
      await Task.yield()
      self?.launch(rowID)
    }
  }

  /// Slides the timeline's content from where it was before a jump of
  /// `delta` points, the scroll that made room for a sent prompt, to where it
  /// is now.
  ///
  /// A lazy stack only keeps rows near its scroll view's visible rect, and
  /// the jump has already moved that rect, so the rows leaving at the top are
  /// gone by the time they'd slide out. A picture of the timeline taken just
  /// before the send covers them, sliding with the content.
  func noteScroll(by delta: CGFloat) {
    guard delta > 0.5, isSending, let scrollView, let layer = scrollView.documentView?.layer else { return }
    let flipped = layer.superlayer?.contentsAreFlipped() ?? true
    layer.add(slide(from: flipped ? delta : -delta), forKey: "promptSlide-\(CACurrentMediaTime())")
    guard let snapshot = snapshot.take(), let host = scrollView.layer else { return }
    // Only the rows above the new visible rect are gone: the top `delta`
    // points of what was on screen. A piece of the picture covers just them,
    // and leaves the screen exactly as the slide ends.
    let clip = scrollView.contentView
    let height = min(delta, clip.bounds.height)
    guard let piece = snapshot.image.cropping(to: CGRect(
      x: 0, y: 0, width: CGFloat(snapshot.image.width), height: (height * snapshot.scale).rounded()
    )) else { return }
    let frame = CALayer()
    frame.frame = clip.frame
    frame.masksToBounds = true
    let cover = CALayer()
    cover.contents = piece
    cover.contentsScale = snapshot.scale
    cover.contentsGravity = .resize
    cover.backgroundColor = snapshot.background
    // Where the rows it shows are now, `delta` above where they were: the
    // slide starts it at the top of the visible rect.
    let hostFlipped = host.contentsAreFlipped()
    cover.frame = CGRect(
      x: 0, y: hostFlipped ? -delta : clip.bounds.height - height + delta,
      width: clip.bounds.width, height: height
    )
    frame.addSublayer(cover)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    CATransaction.setCompletionBlock { frame.removeFromSuperlayer() }
    host.addSublayer(frame)
    cover.add(slide(from: hostFlipped ? delta : -delta), forKey: "promptSlide")
    CATransaction.commit()
  }

  /// The conversation moves up as quickly as the scroll it replaces did, so
  /// the sent bubble, on its slower spring, visibly flies in after it.
  private func slide(from offset: CGFloat) -> CABasicAnimation {
    let slide = CABasicAnimation(keyPath: "transform.translation.y")
    slide.isAdditive = true
    slide.fromValue = offset
    slide.toValue = 0
    slide.duration = 0.25
    slide.timingFunction = CAMediaTimingFunction(name: .easeOut)
    slide.speed = Self.speed
    return slide
  }

  /// The timeline's visible content as it is, before a send changes it.
  private func snapshotTimeline() -> TimelineSnapshot? {
    guard let scrollView, let window = scrollView.window else { return nil }
    let clip = scrollView.contentView
    guard let rep = clip.bitmapImageRepForCachingDisplay(in: clip.bounds) else { return nil }
    clip.cacheDisplay(in: clip.bounds, to: rep)
    guard let image = rep.cgImage else { return nil }
    var background: CGColor?
    scrollView.effectiveAppearance.performAsCurrentDrawingAppearance {
      background = NSColor.windowBackgroundColor.cgColor
    }
    return TimelineSnapshot(image: image, scale: window.backingScaleFactor, background: background)
  }

  func cancelAll() {
    for id in Array(flights.keys) { land(id) }
  }

  private func launch(_ rowID: String) {
    guard let flight = flights[rowID], let destination = flight.destination, let overlay else { return land(rowID) }
    // The copy is drawn again at the row's own size, so it lands exactly on it.
    if abs(flight.layer.bounds.width - destination.width) > 0.5 || abs(flight.layer.bounds.height - destination.height) > 0.5,
       let image = render(flight.bubble, width: destination.width, in: overlay) {
      without {
        flight.layer.contents = image.image
        flight.layer.bounds = CGRect(origin: .zero, size: destination.size)
      }
    }
    let move = CASpringAnimation(perceptualDuration: Self.response, bounce: Self.bounce)
    move.keyPath = "position"
    move.fromValue = NSValue(point: flight.layer.position)
    move.toValue = NSValue(point: CGPoint(x: destination.midX, y: destination.midY))
    let grow = CASpringAnimation(perceptualDuration: Self.response, bounce: Self.bounce)
    grow.keyPath = "transform.scale"
    grow.fromValue = 0.9
    grow.toValue = 1
    let group = CAAnimationGroup()
    group.animations = [move, grow]
    group.duration = move.settlingDuration
    group.speed = Self.speed
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    CATransaction.setCompletionBlock { [weak self] in
      MainActor.assumeIsolated { self?.land(rowID) }
    }
    flight.layer.position = CGPoint(x: destination.midX, y: destination.midY)
    flight.layer.transform = CATransform3DIdentity
    flight.layer.add(group, forKey: "flight")
    CATransaction.commit()
    flight.isFlying = true
  }

  /// The row moved under a flying copy: the copy's target moves with it and
  /// an additive spring carries the copy over, without a jump.
  private func retarget(_ flight: Flight, by delta: CGPoint) {
    let layer = flight.layer
    let catchUp = CASpringAnimation(perceptualDuration: Self.response * 0.6, bounce: 0)
    catchUp.keyPath = "position"
    catchUp.isAdditive = true
    catchUp.fromValue = NSValue(point: CGPoint(x: -delta.x, y: -delta.y))
    catchUp.toValue = NSValue(point: .zero)
    catchUp.duration = catchUp.settlingDuration
    catchUp.speed = Self.speed
    without {
      layer.position = CGPoint(x: layer.position.x + delta.x, y: layer.position.y + delta.y)
      layer.add(catchUp, forKey: "retarget-\(CACurrentMediaTime())")
    }
  }

  private func land(_ rowID: String) {
    laidOut[rowID] = nil
    guard let flight = flights.removeValue(forKey: rowID) else { return }
    flight.expiry?.cancel()
    var transaction = Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction) { _ = hidden.remove(rowID) }
    // The copy stays until the real bubble has drawn under it.
    Task { [layer = flight.layer] in
      try? await Task.sleep(for: .milliseconds(50))
      Self.without { layer.removeFromSuperlayer() }
    }
  }

  private func render(_ bubble: PromptBubbleCopy, width: CGFloat, in view: NSView) -> (image: CGImage, size: CGSize, scale: CGFloat)? {
    guard width > 0 else { return nil }
    let isDark = view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    let renderer = ImageRenderer(content: PromptBubble(text: bubble.text, isFromAgent: bubble.isFromAgent, accent: Color("AccentColor"))
      .font(.system(size: bubble.fontSize))
      .environment(\.colorScheme, isDark ? .dark : .light))
    renderer.proposedSize = ProposedViewSize(width: width, height: nil)
    renderer.scale = view.window?.backingScaleFactor ?? 2
    guard let image = renderer.cgImage else { return nil }
    let size = CGSize(width: CGFloat(image.width) / renderer.scale, height: CGFloat(image.height) / renderer.scale)
    return (image, size, renderer.scale)
  }

  /// A view over the window's content, in its coordinates. It's a sibling of
  /// the content view rather than a subview: SwiftUI's hosting view draws its
  /// own content over views added to it, so a copy there never showed.
  private func overlayView() -> FlightOverlayView? {
    if let overlay, overlay.window != nil { return overlay }
    guard let content = scrollView?.window?.contentView, let frame = content.superview else { return nil }
    let view = FlightOverlayView(frame: content.frame)
    view.autoresizingMask = [.width, .height]
    frame.addSubview(view, positioned: .above, relativeTo: content)
    overlay = view
    return view
  }

  private func without(_ changes: () -> Void) { Self.without(changes) }

  private static func without(_ changes: () -> Void) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    changes()
    CATransaction.commit()
  }

  #if DEBUG
  /// `ATRIUM_DEBUG_SLOWMO=10` plays the send ten times slower, to check it by eye.
  private static let speed = 1 / (Float(ProcessInfo.processInfo.environment["ATRIUM_DEBUG_SLOWMO"] ?? "") ?? 1)
  #else
  private static let speed: Float = 1
  #endif
}

/// A picture of the timeline's visible content.
struct TimelineSnapshot {
  let image: CGImage
  let scale: CGFloat
  let background: CGColor?
}

private extension Optional {
  /// The value, leaving nil behind.
  mutating func take() -> Wrapped? {
    defer { self = nil }
    return self
  }
}

/// What a flying copy shows.
struct PromptBubbleCopy {
  let text: String
  var isFromAgent = false
  let fontSize: CGFloat
}

/// Holds flying copies above the window's content; clicks pass through.
final class FlightOverlayView: NSView {
  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.masksToBounds = false
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override var isFlipped: Bool { true }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Hides a prompt's bubble while its copy flies in and reports where it lands.
struct PromptFlightTarget: ViewModifier {
  let rowID: String?
  @Environment(PromptFlights.self) private var flights: PromptFlights?

  func body(content: Content) -> some View {
    if let rowID, let flights {
      content
        .opacity(flights.hidden.contains(rowID) ? 0 : 1)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
          flights.noteDestination(rowID, frame: frame)
        }
    } else {
      content
    }
  }
}

/// Finds the timeline's `NSScrollView`, whose content slides on the render server.
struct TimelineScrollViewFinder: NSViewRepresentable {
  let flights: PromptFlights

  func makeNSView(context: Context) -> FinderView {
    let view = FinderView()
    view.flights = flights
    return view
  }

  func updateNSView(_ nsView: FinderView, context: Context) {
    nsView.flights = flights
  }

  final class FinderView: NSView {
    weak var flights: PromptFlights?

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      if let scrollView = enclosingScrollView { flights?.scrollView = scrollView }
    }
  }
}
