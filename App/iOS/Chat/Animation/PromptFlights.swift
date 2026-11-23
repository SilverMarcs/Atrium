import QuartzCore
import SwiftUI
import UIKit

/// Flies a just-sent prompt from the composer to its place in the timeline as
/// a Core Animation layer above the window, and slides the conversation up to
/// make room the same way.
///
/// The render server runs both animations, so they keep their frames while
/// the main thread is busy with what a send sets off: the timeline laying out
/// the prompt's turn, the keyboard closing and the composer collapsing, the
/// host's task and transcript updates. SwiftUI animations, `TimelineView`
/// clocks and animated `scrollTo`s step on the main thread and lose frames to
/// all of it.
///
/// The real bubble stays hidden under its copy until the copy lands, so the
/// timeline itself never animates.
@MainActor
@Observable
final class PromptFlights: PromptSendAnimating {
    /// The prompts flying in. Rows look theirs up here.
    private(set) var flights: [PromptFlight] = []

    @ObservationIgnored var sourceFrame: (() -> CGRect?)?
    @ObservationIgnored var reduceMotion = false
    /// How the timeline draws its bubbles, for the copy.
    @ObservationIgnored var dynamicTypeSize: DynamicTypeSize = .large
    @ObservationIgnored var colorScheme: ColorScheme = .light
    /// The chat's skills, which the copy tints as its bubble does.
    @ObservationIgnored var skillNames: Set<String> = []
    /// How wide the timeline's rows are, which sizes the copy before its row lays out.
    @ObservationIgnored var rowWidth: CGFloat = 0
    /// The timeline's scroll view, whose content slides on the render server.
    @ObservationIgnored weak var scrollView: UIScrollView?
    @ObservationIgnored private weak var overlay: FlightOverlayView?
    /// When the latest prompt was sent, so the scroll that follows it jumps and slides.
    @ObservationIgnored private var sentAt: CFTimeInterval = 0
    /// The scroll that makes room for a sent prompt, until it lands.
    @ObservationIgnored private var room: Task<Void, Never>?
    /// Whether the scroll for a sent prompt is yet to be asked for, so the
    /// timeline moving meanwhile isn't it landing.
    @ObservationIgnored private var awaitsRoomScroll = false
    /// The timeline as it was just before the latest send.
    @ObservationIgnored private var snapshot: TimelineSnapshot?

    /// Matches the spring the bubble flew with before (response 0.36, damping 0.8).
    static let response: CGFloat = 0.36
    static let bounce: CGFloat = 0.2
    /// Leading space a prompt bubble leaves in its row.
    static let bubbleInset: CGFloat = 60

    /// Whether a prompt was just sent, so the scroll that makes room for it
    /// jumps and slides on the render server.
    var isSending: Bool { CACurrentMediaTime() - sentAt < 0.5 }

    func willSend() {
        sentAt = reduceMotion ? 0 : CACurrentMediaTime()
        snapshot = reduceMotion ? nil : snapshotTimeline()
    }

    /// Shows a copy of the prompt's bubble over the composer, and hides the
    /// row's own bubble. A prompt without images flies at once to the top of
    /// the timeline, where it's held, and the copy follows its row there once
    /// the timeline has laid it out; any other waits for the row.
    func begin(_ promptID: PendingPrompt.ID, text: String, hasImages: Bool, from source: CGRect?) {
        guard !text.isEmpty, !reduceMotion, let source, source.width > 0, let overlay = overlayView() else { return }
        // Even hardware-keyboard repeats keep only a few copies.
        if flights.count >= 8, let oldest = flights.first { land(oldest) }
        // The row's bubble hides before the copy is drawn: drawing it can
        // run the update that lays out the row. Not in `withTransaction`,
        // which runs that update first, where the row misses the flight and
        // never hears of it.
        let flight = PromptFlight(id: promptID, text: text)
        flights.append(flight)
        guard let image = render(text, width: rowWidth - Self.bubbleInset) else { return land(flight) }
        let layer = flight.layer
        layer.contents = image.image
        layer.contentsScale = image.scale
        layer.bounds = CGRect(origin: .zero, size: image.size)
        // Its trailing edge on the field's, as the bubble's sits in its row.
        layer.position = CGPoint(x: source.maxX - image.size.width / 2, y: source.midY)
        layer.transform = CATransform3DMakeScale(0.9, 0.9, 1)
        Self.withoutAnimation { overlay.layer.addSublayer(layer) }
        overlay.superview?.bringSubviewToFront(overlay)
        if !hasImages, let destination = heldDestination(size: image.size) {
            flight.awaitsRoom = true
            fly(flight, to: destination)
            // Where the row lays out counts once the timeline has scrolled for it.
            if room == nil {
                awaitsRoomScroll = true
                settleRoom(after: .milliseconds(250))
            }
        }
        // A row that never lays out shows anyway.
        flight.expiry = Task { [weak self, weak flight] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self, let flight else { return }
            land(flight)
        }
    }

    func confirm(_ promptID: PendingPrompt.ID, as messageID: TranscriptMessage.ID) {
        flights.first { $0.id == promptID }?.confirmedMessageID = messageID
    }

    func flight(forPending id: PendingPrompt.ID) -> PromptFlight? {
        flights.first { $0.id == id }
    }

    func flight(forConfirmed id: TranscriptMessage.ID) -> PromptFlight? {
        flights.first { $0.confirmedMessageID == id }
    }

    /// Where the row's bubble is, in window coordinates, each time it moves.
    func noteDestination(_ flight: PromptFlight, frame: CGRect) {
        guard flights.contains(where: { $0 === flight }), frame.width > 0 else { return }
        // A copy already on its way to where the row will be held follows
        // the row once the scroll for it has landed, not to where the row
        // first lays out.
        if flight.awaitsRoom {
            flight.laidOut = frame
            return
        }
        let previous = flight.destination
        flight.destination = frame
        if flight.isFlying, let previous, previous != frame {
            retarget(flight, by: CGPoint(x: frame.midX - previous.midX, y: frame.midY - previous.midY))
            return
        }
        // Fly to where the row settles, once the scroll that makes room for
        // it has landed.
        guard !flight.isLaunching, room == nil else { return }
        flight.isLaunching = true
        Task { [weak self, weak flight] in
            await Task.yield()
            guard let self, let flight else { return }
            launch(flight)
        }
    }

    /// Scrolls to make room for a sent prompt without animating, and slides
    /// the content there on the render server as the timeline moves. Copies
    /// on their way follow their rows once it lands.
    ///
    /// Asked for after the update that lays out the prompt's row: in that
    /// update, the timeline above it is still being measured, and a scroll
    /// to hold a prompt sent while the agent works fell short of the top.
    func makeRoom(by scroll: @escaping () -> Void) {
        awaitsRoomScroll = true
        settleRoom(after: .milliseconds(250))
        Task {
            await Task.yield()
            scroll()
            awaitsRoomScroll = false
            // The timeline may already be where the scroll takes it.
            settleRoom(after: .milliseconds(100))
        }
    }

    /// The timeline's offset moved by `delta` points. While a sent prompt's
    /// scroll is landing, the content slides from where it was instead.
    func noteScroll(by delta: CGFloat) {
        guard room != nil, abs(delta) > 0.5 else { return }
        if !reduceMotion { slide(by: delta) }
        // Landed once the update that moved it has laid out the rows there.
        if !awaitsRoomScroll { settleRoom(after: nil) }
    }

    /// Lands the room after `delay`, or once the current update is done.
    private func settleRoom(after delay: Duration?) {
        room?.cancel()
        room = Task { [weak self] in
            if let delay { try? await Task.sleep(for: delay) } else { await Task.yield() }
            guard !Task.isCancelled, let self else { return }
            room = nil
            awaitsRoomScroll = false
            for flight in flights {
                if flight.awaitsRoom {
                    flight.awaitsRoom = false
                    if let frame = flight.laidOut { noteDestination(flight, frame: frame) }
                } else if !flight.isLaunching, let frame = flight.destination {
                    noteDestination(flight, frame: frame)
                }
            }
        }
    }

    /// Slides the timeline's content, and the chrome UIKit pins to its
    /// viewport, from where they were before a jump of `delta` points.
    ///
    /// A lazy stack only keeps rows near its scroll view's visible rect, and
    /// the jump has already moved that rect, so the rows leaving the screen
    /// are gone by the time they'd slide out. A picture of the timeline taken
    /// just before the send covers them, sliding with the content.
    private func slide(by delta: CGFloat) {
        guard let scrollView else { return }
        let key = "atrium.sendSlide-\(CACurrentMediaTime())"
        CATransaction.begin()
        if let cover = cover(leaving: delta, in: scrollView) {
            CATransaction.setCompletionBlock { cover.removeFromSuperview() }
        }
        scrollView.layer.add(slide(from: -delta), forKey: key)
        // Offsetting the bounds moves the scroll edge effects and indicators
        // with the content; their own offset takes it back out.
        for view in pinnedSubviews(of: scrollView) {
            let pinned = slide(from: -delta)
            pinned.keyPath = "position"
            view.layer.add(pinned, forKey: key)
        }
        CATransaction.commit()
    }

    /// The part of the picture taken before the send that a jump of `delta`
    /// points takes off screen, placed where those rows are in the content
    /// so it slides out with it, above the content and below the chrome.
    private func cover(leaving delta: CGFloat, in scrollView: UIScrollView) -> UIView? {
        guard let snapshot = snapshot.take(), let content = contentView(of: scrollView) else { return nil }
        let visible = snapshot.visibleRect
        let height = min(abs(delta), visible.height)
        // Moving down through the conversation, the top of what was on
        // screen leaves; moving back, the bottom.
        let strip = CGRect(x: visible.minX, y: delta > 0 ? visible.minY : visible.maxY - height, width: visible.width, height: height)
        let cover = SlideCoverView(frame: strip)
        cover.clipsToBounds = true
        cover.backgroundColor = scrollView.backgroundColor ?? .systemBackground
        snapshot.view.frame = CGRect(origin: CGPoint(x: 0, y: visible.minY - strip.minY), size: visible.size)
        cover.addSubview(snapshot.view)
        scrollView.insertSubview(cover, aboveSubview: content)
        return cover
    }

    /// The timeline's visible content as it is, before a send changes it:
    /// drawn by the render server, without the chrome pinned over it.
    private func snapshotTimeline() -> TimelineSnapshot? {
        guard let scrollView, let content = contentView(of: scrollView) else { return nil }
        let visible = scrollView.bounds
        guard let view = content.resizableSnapshotView(
            from: content.convert(visible, from: scrollView), afterScreenUpdates: false, withCapInsets: .zero
        ) else { return nil }
        return TimelineSnapshot(view: view, visibleRect: visible)
    }

    /// Where a bubble of `size` is held at the top of the timeline: its top
    /// at the top of what the bars leave visible, its trailing edge on the rows'.
    private func heldDestination(size: CGSize) -> CGRect? {
        guard let scrollView, let window = scrollView.window else { return nil }
        let visible = scrollView.convert(scrollView.bounds, to: window)
        let insets = scrollView.adjustedContentInset
        return CGRect(x: visible.maxX - insets.right - size.width, y: visible.minY + insets.top,
                      width: size.width, height: size.height)
    }

    /// The SwiftUI content of the timeline's scroll view.
    private func contentView(of scrollView: UIScrollView) -> UIView? {
        scrollView.subviews.first { !($0 is SlideCoverView) && !NSStringFromClass(type(of: $0)).hasPrefix("_UI") }
    }

    /// UIKit's chrome inside the scroll view, which it keeps fixed to the
    /// viewport: the scroll edge effects behind the bars, and the scroll indicators.
    private func pinnedSubviews(of scrollView: UIScrollView) -> [UIView] {
        scrollView.subviews.filter { NSStringFromClass(type(of: $0)).hasPrefix("_UI") }
    }

    /// The conversation moves up as quickly as the scroll it replaces did, so
    /// the sent bubble, on its slower spring, visibly flies in after it.
    private func slide(from offset: CGFloat) -> CABasicAnimation {
        let slide = CABasicAnimation(keyPath: "bounds.origin")
        slide.isAdditive = true
        slide.fromValue = NSValue(cgPoint: CGPoint(x: 0, y: offset))
        slide.toValue = NSValue(cgPoint: .zero)
        slide.duration = 0.25
        slide.timingFunction = CAMediaTimingFunction(name: .easeOut)
        slide.speed = Self.speed
        return slide
    }

    func cancelAll() {
        room?.cancel()
        room = nil
        awaitsRoomScroll = false
        for flight in flights { land(flight, drawingNow: false) }
    }

    private func launch(_ flight: PromptFlight) {
        // A scroll asked for since waits to land first.
        guard room == nil else {
            flight.isLaunching = false
            return
        }
        guard let destination = flight.destination else { return land(flight) }
        let layer = flight.layer
        // The copy is drawn again at the row's own size, so it lands exactly on it.
        if abs(layer.bounds.width - destination.width) > 0.5 || abs(layer.bounds.height - destination.height) > 0.5,
           let image = render(flight.text, width: destination.width) {
            Self.withoutAnimation {
                layer.contents = image.image
                layer.bounds = CGRect(origin: .zero, size: destination.size)
            }
        }
        fly(flight, to: destination)
    }

    private func fly(_ flight: PromptFlight, to destination: CGRect) {
        let layer = flight.layer
        flight.destination = destination
        flight.isLaunching = true
        let move = CASpringAnimation(perceptualDuration: Self.response, bounce: Self.bounce)
        move.keyPath = "position"
        move.fromValue = NSValue(cgPoint: layer.position)
        move.toValue = NSValue(cgPoint: CGPoint(x: destination.midX, y: destination.midY))
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
        CATransaction.setCompletionBlock { [weak self, weak flight] in
            MainActor.assumeIsolated {
                guard let self, let flight else { return }
                self.land(flight)
            }
        }
        layer.position = CGPoint(x: destination.midX, y: destination.midY)
        layer.transform = CATransform3DIdentity
        layer.add(group, forKey: "flight")
        CATransaction.commit()
        flight.isFlying = true
    }

    /// The row moved under a flying copy: the copy's target moves with it and
    /// an additive spring carries the copy over, without a jump.
    private func retarget(_ flight: PromptFlight, by delta: CGPoint) {
        let layer = flight.layer
        let catchUp = CASpringAnimation(perceptualDuration: Self.response * 0.6, bounce: 0)
        catchUp.keyPath = "position"
        catchUp.isAdditive = true
        catchUp.fromValue = NSValue(cgPoint: CGPoint(x: -delta.x, y: -delta.y))
        catchUp.toValue = NSValue(cgPoint: .zero)
        catchUp.duration = catchUp.settlingDuration
        catchUp.speed = Self.speed
        Self.withoutAnimation {
            layer.position = CGPoint(x: layer.position.x + delta.x, y: layer.position.y + delta.y)
            layer.add(catchUp, forKey: "retarget-\(CACurrentMediaTime())")
        }
    }

    private func land(_ flight: PromptFlight, drawingNow: Bool = true) {
        guard let index = flights.firstIndex(where: { $0 === flight }) else { return }
        flight.expiry?.cancel()
        flights.remove(at: index)
        // The real bubble and its copy swap in one frame. Shown together, their
        // translucent tints stack into a flash of brighter colour; with the copy
        // gone first, the bubble would blink out. Laying out now draws the real
        // bubble in the same commit that removes the copy.
        if drawingNow { scrollView?.window?.layoutIfNeeded() }
        Self.withoutAnimation { flight.layer.removeFromSuperlayer() }
    }

    private func render(_ text: String, width: CGFloat) -> (image: CGImage, size: CGSize, scale: CGFloat)? {
        guard width > 0 else { return nil }
        let renderer = ImageRenderer(content: PromptBubble(text: text, accent: Color("AccentColor"))
            .environment(\.dynamicTypeSize, dynamicTypeSize)
            .environment(\.skillNames, skillNames)
            .environment(\.colorScheme, colorScheme))
        renderer.proposedSize = ProposedViewSize(width: width, height: nil)
        renderer.scale = scrollView?.traitCollection.displayScale ?? 3
        guard let image = renderer.cgImage else { return nil }
        let size = CGSize(width: CGFloat(image.width) / renderer.scale, height: CGFloat(image.height) / renderer.scale)
        return (image, size, renderer.scale)
    }

    /// A view over the window's content, in its coordinates, which UIKit
    /// leaves out of hit testing.
    private func overlayView() -> FlightOverlayView? {
        guard let window = scrollView?.window else { return nil }
        if let overlay, overlay.window === window { return overlay }
        overlay?.removeFromSuperview()
        let view = FlightOverlayView(frame: window.bounds)
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        window.addSubview(view)
        overlay = view
        return view
    }

    private static func withoutAnimation(_ changes: () -> Void) {
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

/// A picture of the timeline's visible content, and where in the content it was.
private struct TimelineSnapshot {
    let view: UIView
    let visibleRect: CGRect
}

/// Covers rows leaving the timeline while its content slides.
private final class SlideCoverView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private extension Optional {
    /// The value, leaving nil behind.
    mutating func take() -> Wrapped? {
        defer { self = nil }
        return self
    }
}

/// One prompt's flight. It outlives the pending row being replaced by the
/// transcript's message, which then waits under the copy instead.
@MainActor
final class PromptFlight {
    let id: PendingPrompt.ID
    let text: String
    var confirmedMessageID: TranscriptMessage.ID?
    let layer = CALayer()
    var destination: CGRect?
    /// Flying to where the row will be held, until the scroll for it lands.
    var awaitsRoom = false
    /// Where the row laid out meanwhile.
    var laidOut: CGRect?
    var isLaunching = false
    var isFlying = false
    var expiry: Task<Void, Never>?

    init(id: PendingPrompt.ID, text: String) {
        self.id = id
        self.text = text
    }
}

/// Holds flying copies above the window's content; touches pass through.
final class FlightOverlayView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        layer.masksToBounds = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// Hides a prompt's bubble while its copy flies in, and reports where it
/// lands. The bubble's views are the same with or without a flight, so
/// landing never rebuilds it.
struct PromptFlightTarget: ViewModifier {
    @Environment(PromptFlights.self) private var flights: PromptFlights?
    /// Finds this bubble's flight, if it was just sent. Nil for a bubble that
    /// can't have one, which then never observes flights.
    let flight: ((PromptFlights) -> PromptFlight?)?

    func body(content: Content) -> some View {
        let flight = flights.flatMap { flights in self.flight?(flights) }
        content
            .opacity(flight == nil ? 1 : 0)
            // Its copy covers it, so it shows and hides at once.
            .animation(nil, value: flight == nil)
            .background {
                // Measured only while it flies, as a frame in the window
                // changes with every scrolled frame.
                if let flight, let flights {
                    Color.clear
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                            flights.noteDestination(flight, frame: frame)
                        }
                }
            }
    }
}

/// Finds the timeline's `UIScrollView`, whose content slides on the render server.
struct TimelineScrollViewFinder: View {
    let flights: PromptFlights

    var body: some View {
        EnclosingScrollViewIntrospector { scrollView in
            flights.scrollView = scrollView
        } onDetach: { scrollView in
            if flights.scrollView === scrollView { flights.scrollView = nil }
        }
        .accessibilityHidden(true)
    }
}
