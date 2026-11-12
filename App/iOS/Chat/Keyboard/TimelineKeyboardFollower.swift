import UIKit

/// Moves a timeline kept at its newest message with the composer as the
/// keyboard shows and hides, and as the composer grows and shrinks.
///
/// SwiftUI moves the composer with the keyboard in a Core Animation spring on
/// the composer's container, and lays out its growing or shrinking frame by
/// frame, while it gives the timeline its new safe area, and offset, in one
/// step. Left alone, the timeline jumps to where it ends while the composer
/// is still on its way.
///
/// While a move runs, this copies that spring onto the timeline's
/// `bounds.origin`, so the render server draws both on one clock, and holds
/// an additive offset for the rest: the timeline's end kept above wherever
/// the composer is laid out in that frame. The scroll view's real offset is
/// left to SwiftUI, so scrolling state and hit testing are unchanged once the
/// move ends.
///
/// SwiftUI starts the spring, and lays the composer out, inside the commit,
/// with the spring starting a little in the past, so the timeline is held
/// again from the commit's display phase (`ComposerKeyboardAnchorView`), as
/// well as before the commit and as its offset changes.
@MainActor
final class TimelineKeyboardFollower {
    private struct Follow {
        /// When the latest move began; another can begin before one ends.
        var startTime: CFTimeInterval
        /// The timeline's safe area in the last pass, and when it last changed.
        var safeAreaBottom: CGFloat
        var safeAreaChangedAt: CFTimeInterval
        /// The held additive offset drawn in the last commit.
        var additive: CGFloat = 0
        /// The composer's keyboard spring the timeline mirrors.
        var mirrored: KeyboardSpring.ID?
    }

    /// The key UIKit animates scroll offset corrections under.
    private static let systemAnimationKey = "bounds.origin"
    private static let animationKey = "atrium.keyboardFollow"
    private static let mirrorKey = "atrium.keyboardFollow.spring"
    /// Ends a follow whose composer or timeline never settles.
    private static let maximumDuration: CFTimeInterval = 1
    private static let minimumDuration: CFTimeInterval = 0.1
    /// How long the safe area must hold still to count as settled. Passes can
    /// run several times within one frame.
    private static let safeAreaSettleDuration: CFTimeInterval = 0.05

    /// Whether the timeline keeps its end above the composer, rather than
    /// being scrolled back by the reader or holding a prompt at the top.
    /// Otherwise the keyboard moves over a timeline that stays put.
    var followsLatest: () -> Bool = { true }
    private weak var scrollView: UIScrollView?
    private weak var anchor: ComposerKeyboardAnchorView?
    private var observer: CFRunLoopObserver?
    private var offsetObservation: NSKeyValueObservation?
    private var notificationTokens: [any NSObjectProtocol] = []
    private var follow: Follow?
    /// Ends a follow whose passes stopped before it did.
    private var timeout: Task<Void, Never>?
    /// Wakes the main run loop every frame while following, as the composer
    /// can ride the keyboard with nothing else running on the main thread.
    private var frameTicker: CADisplayLink?

    func attach(to scrollView: UIScrollView) {
        guard self.scrollView !== scrollView || notificationTokens.isEmpty else { return }
        detach()
        self.scrollView = scrollView
        let center = NotificationCenter.default
        let begin: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.moveBegan(isShowing: true) }
        }
        let end: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.moveBegan(isShowing: false) }
        }
        notificationTokens = [
            // The composer only grows or shrinks once its editor has gained
            // or lost focus, which UIKit announces before the keyboard moves.
            center.addObserver(forName: UITextView.textDidBeginEditingNotification, object: nil, queue: .main) { notification in
                if notification.object is ComposerEditor { begin(notification) }
            },
            center.addObserver(forName: UITextView.textDidEndEditingNotification, object: nil, queue: .main) { notification in
                if notification.object is ComposerEditor { end(notification) }
            },
            // A line more or less in the draft grows or shrinks it.
            center.addObserver(forName: ComposerEditor.willResizeNotification, object: nil, queue: .main, using: end),
            // SwiftUI handles these before this does, starting the composer's
            // spring there.
            center.addObserver(forName: UIResponder.keyboardWillShowNotification, object: nil, queue: .main, using: begin),
            center.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main, using: end),
        ]
    }

    /// A disappearing old viewport must not detach its replacement.
    func detach(from scrollView: UIScrollView) {
        guard self.scrollView === scrollView else { return }
        detach()
    }

    func detach() {
        notificationTokens.forEach(NotificationCenter.default.removeObserver)
        notificationTokens = []
        endFollow(settling: false)
        stopObserving()
        scrollView = nil
    }

    /// The composer or keyboard started to move: a follow already running
    /// carries on, and otherwise one starts if the timeline is at its end, or
    /// close enough for opening the composer to take it there.
    private func moveBegan(isShowing: Bool) {
        guard let scrollView, scrollView.window != nil else { return }
        if follow != nil {
            follow?.startTime = CACurrentMediaTime()
            applyFollow(to: scrollView)
            requestCommitCallback()
            return
        }
        guard followsLatest(), currentComposer() != nil,
              !scrollView.isDragging, !scrollView.isDecelerating else { return }
        let distance = endOffset(of: scrollView) - scrollView.contentOffset.y
        guard isShowing ? distance < scrollView.bounds.height : abs(distance) < 8 else { return }
        startFollow(in: scrollView)
    }

    // MARK: - Commit hook

    private func startObserving() {
        guard observer == nil else { return }
        // Core Animation commits at order 2,000,000; run just before it.
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, 1_999_000) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.beforeCommit() }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.observer = observer
    }

    private func stopObserving() {
        guard let observer else { return }
        CFRunLoopObserverInvalidate(observer)
        self.observer = nil
    }

    private func beforeCommit() {
        guard let scrollView, scrollView.window != nil, follow != nil else {
            endFollow(settling: false)
            stopObserving()
            return
        }
        updateFollow(in: scrollView)
        requestCommitCallback()
    }

    // MARK: - Following

    private func startFollow(in scrollView: UIScrollView) {
        let now = CACurrentMediaTime()
        follow = Follow(startTime: now, safeAreaBottom: scrollView.safeAreaInsets.bottom, safeAreaChangedAt: now)
        startObserving()
        // SwiftUI may set the offset again during the commit, as layout runs.
        offsetObservation = scrollView.observe(\.contentOffset) { [weak self] scrollView, _ in
            MainActor.assumeIsolated { self?.applyFollow(to: scrollView) }
        }
        applyFollow(to: scrollView)
        requestCommitCallback()
        // Passes only run when the main run loop wakes. After a send, nothing
        // may wake it until the host answers, which would leave the timeline
        // drawn at the held offset, away from where its lazy rows are built.
        if frameTicker == nil {
            let ticker = CADisplayLink(target: FrameTickTarget.shared, selector: #selector(FrameTickTarget.tick))
            ticker.add(to: .main, forMode: .common)
            frameTicker = ticker
        }
        timeout?.cancel()
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.maximumDuration))
            guard !Task.isCancelled else { return }
            self?.endFollow(settling: true)
        }
    }

    private func updateFollow(in scrollView: UIScrollView) {
        guard var follow, let composer = currentComposer() else { return }
        let now = CACurrentMediaTime()
        let safeAreaBottom = scrollView.safeAreaInsets.bottom
        if safeAreaBottom != follow.safeAreaBottom {
            follow.safeAreaBottom = safeAreaBottom
            follow.safeAreaChangedAt = now
            self.follow = follow
        }
        applyFollow(to: scrollView)

        // The move is announced before SwiftUI makes it, so a follow that
        // has just started has nothing to settle from yet.
        let isSettled = now - follow.startTime >= Self.minimumDuration
            && keyboardSpring(above: composer) == nil
            && now - follow.safeAreaChangedAt >= Self.safeAreaSettleDuration
            && abs(composerDisplacement(of: composer)) < 0.5
            && abs(self.follow?.additive ?? 0) < 0.5
        if isSettled {
            endFollow(settling: true)
        } else if scrollView.isDragging || now - follow.startTime > Self.maximumDuration {
            // A drag, or a move that never settled, hands the rest to an
            // animation. A tap, as on the timeline to close the composer,
            // doesn't.
            endFollow(settling: true)
        }
    }

    /// Holds the timeline's end above the composer as laid out in this
    /// commit, with the keyboard's spring mirrored on top.
    private func applyFollow(to scrollView: UIScrollView) {
        guard var follow else { return }
        var layoutLag: CGFloat = 0
        var unmirrored: CGFloat = 0
        if let composer = currentComposer(), let window = scrollView.window {
            // The spring counts as handled only once it's mirrored, in the
            // same commit as this. Until SwiftUI adds it, the composer is
            // still drawn where it was, which the timeline is held against.
            var springDisplacement: CGFloat = 0
            if let spring = keyboardSpring(above: composer) {
                if follow.mirrored != spring.id {
                    mirror(spring, in: scrollView)
                    follow.mirrored = spring.id
                }
                springDisplacement = spring.displacement
            }
            unmirrored = composerDisplacement(of: composer) - springDisplacement
            // The composer's anchor tops its bar, at the safe area's edge
            // once SwiftUI has laid it out at its new size.
            let safeAreaEdge = scrollView.convert(scrollView.bounds, to: window).maxY - scrollView.safeAreaInsets.bottom
            layoutLag = composer.convert(composer.bounds, to: window).minY - safeAreaEdge
        }
        let additive = endOffset(of: scrollView) - scrollView.contentOffset.y - layoutLag - unmirrored
        let layer = scrollView.layer
        // UIKit's own corrections would add to this one, and it moves the
        // chrome pinned to the viewport along with them.
        for key in layer.animationKeys() ?? [] where key.hasPrefix(Self.systemAnimationKey) {
            layer.removeAnimation(forKey: key)
        }
        for view in pinnedSubviews(of: scrollView) {
            for key in view.layer.animationKeys() ?? [] where key.hasPrefix("position") {
                view.layer.removeAnimation(forKey: key)
            }
        }
        if abs(additive - follow.additive) > 0.01 || layer.animation(forKey: Self.animationKey) == nil {
            follow.additive = additive
            layer.add(heldOffset(additive, keyPath: Self.systemAnimationKey), forKey: Self.animationKey)
            // Holding them in place draws them where UIKit already has them.
            for view in pinnedSubviews(of: scrollView) {
                view.layer.add(heldOffset(additive, keyPath: "position"), forKey: Self.animationKey)
            }
        }
        self.follow = follow
    }

    /// Copies the composer's keyboard spring onto the timeline, inverted: the
    /// composer drawn lower than its model means the timeline's end is too.
    private func mirror(_ spring: KeyboardSpring, in scrollView: UIScrollView) {
        guard let copy = spring.animation.copy() as? CABasicAnimation else { return }
        copy.isAdditive = true
        copy.fromValue = NSValue(cgPoint: CGPoint(x: 0, y: -spring.from))
        copy.toValue = NSValue(cgPoint: CGPoint(x: 0, y: -spring.to))
        copy.isRemovedOnCompletion = true
        // Before it starts, it holds the timeline where the composer is drawn.
        copy.fillMode = .backwards
        // Core Animation stamps the spring's start in the render tree, not on
        // the copy here. Found after it began, as after a stall, it's
        // started as far back as the composer has already come.
        if copy.beginTime == 0, let elapsed = elapsedTime(of: spring) {
            copy.beginTime = CACurrentMediaTime() - elapsed
        }
        copy.keyPath = Self.systemAnimationKey
        scrollView.layer.add(copy, forKey: Self.mirrorKey)
        for view in pinnedSubviews(of: scrollView) {
            guard let pinned = copy.copy() as? CABasicAnimation else { continue }
            pinned.keyPath = "position"
            view.layer.add(pinned, forKey: Self.mirrorKey)
        }
    }

    /// How long a spring found running has been going, from how far it has
    /// brought the composer: nil before it has moved it.
    private func elapsedTime(of spring: KeyboardSpring) -> CFTimeInterval? {
        guard let animation = spring.animation as? CASpringAnimation, spring.from != spring.to else { return nil }
        let remaining = (spring.displacement - spring.to) / (spring.from - spring.to)
        guard remaining < 0.99, remaining > 0 else { return nil }
        let omega = (animation.stiffness / animation.mass).squareRoot()
        let zeta = animation.damping / (2 * (animation.stiffness * animation.mass).squareRoot())
        // The share of the way still to go, which falls from 1 as it runs.
        func left(at t: Double) -> Double {
            if zeta < 1 {
                let damped = omega * (1 - zeta * zeta).squareRoot()
                return exp(-zeta * omega * t) * (cos(damped * t) + zeta * omega / damped * sin(damped * t))
            }
            if zeta == 1 { return (1 + omega * t) * exp(-omega * t) }
            let root = (zeta * zeta - 1).squareRoot()
            let fast = -omega * (zeta - root), slow = -omega * (zeta + root)
            return (slow * exp(fast * t) - fast * exp(slow * t)) / (slow - fast)
        }
        var low = 0.0, high = animation.duration
        for _ in 0..<30 {
            let mid = (low + high) / 2
            if left(at: mid) > Double(remaining) { low = mid } else { high = mid }
        }
        return (low + high) / 2
    }

    /// UIKit's chrome inside the scroll view, which it keeps fixed to the
    /// viewport: the scroll edge effects behind the bars, and the scroll
    /// indicators. Offsetting the scroll view's bounds moves them with the
    /// content, so they're held in place too.
    private func pinnedSubviews(of scrollView: UIScrollView) -> [UIView] {
        scrollView.subviews.filter { NSStringFromClass(type(of: $0)).hasPrefix("_UI") }
    }

    /// Where a timeline kept at its end rests above the current safe area, or
    /// its top when it's shorter than the view.
    private func endOffset(of scrollView: UIScrollView) -> CGFloat {
        let end = scrollView.contentSize.height - scrollView.bounds.height
            + scrollView.contentInset.bottom + scrollView.safeAreaInsets.bottom
        return max(end, -scrollView.adjustedContentInset.top)
    }

    /// An additive offset held until the next pass replaces it.
    private func heldOffset(_ offset: CGFloat, keyPath: String) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.isAdditive = true
        animation.fromValue = NSValue(cgPoint: CGPoint(x: 0, y: offset))
        animation.toValue = animation.fromValue
        animation.duration = Self.maximumDuration
        animation.fillMode = .both
        animation.isRemovedOnCompletion = false
        return animation
    }

    private func endFollow(settling: Bool) {
        guard let follow else { return }
        self.follow = nil
        offsetObservation = nil
        frameTicker?.invalidate()
        frameTicker = nil
        timeout?.cancel()
        timeout = nil
        guard let scrollView else { return }
        let layers = [(scrollView.layer, Self.systemAnimationKey)]
            + pinnedSubviews(of: scrollView).map { ($0.layer, "position") }
        for (layer, keyPath) in layers {
            layer.removeAnimation(forKey: Self.animationKey)
            // A drag takes over mid-spring.
            if !settling || scrollView.isDragging { layer.removeAnimation(forKey: Self.mirrorKey) }
            guard settling, abs(follow.additive) > 0.25 else { continue }
            let settle = CABasicAnimation(keyPath: keyPath)
            settle.isAdditive = true
            settle.fromValue = NSValue(cgPoint: CGPoint(x: 0, y: follow.additive))
            settle.toValue = NSValue(cgPoint: .zero)
            settle.duration = 0.15
            settle.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(settle, forKey: Self.animationKey)
        }
    }

    // MARK: - Composer

    /// The composer in view: a screen kept behind the task list can leave
    /// another in the window.
    private func currentComposer() -> ComposerKeyboardAnchorView? {
        guard let window = scrollView?.window else { return nil }
        if let anchor, anchor.window === window, !anchor.isHiddenInWindow { return anchor }
        anchor?.onCommit = nil
        anchor = findComposer(in: window)
        anchor?.onCommit = { [weak self] in
            guard let self, self.follow != nil, let scrollView = self.scrollView else { return }
            self.applyFollow(to: scrollView)
        }
        return anchor
    }

    private func requestCommitCallback() {
        currentComposer()?.setNeedsCommitCallback()
    }

    /// How far below its model position the composer is drawn.
    private func composerDisplacement(of composer: UIView) -> CGFloat {
        guard let window = composer.window, let presented = composer.layer.presentation() else { return 0 }
        return presented.convert(presented.bounds, to: nil).minY - composer.convert(composer.bounds, to: window).minY
    }

    private struct KeyboardSpring {
        struct ID: Equatable {
            let layer: ObjectIdentifier
            let key: String
            let beginTime: CFTimeInterval
        }

        let animation: CABasicAnimation
        let id: ID
        /// The additive vertical offset it runs from and to.
        let from: CGFloat
        let to: CGFloat
        /// Its offset in the frame on screen now.
        let displacement: CGFloat
    }

    /// The additive position animation SwiftUI moves the composer's container
    /// with as the keyboard shows or hides, while it runs.
    private func keyboardSpring(above composer: UIView) -> KeyboardSpring? {
        let now = CACurrentMediaTime()
        var layer = composer.layer.superlayer
        while let current = layer {
            for key in current.animationKeys() ?? [] {
                guard let animation = current.animation(forKey: key) as? CABasicAnimation,
                      animation.keyPath == "position", animation.isAdditive,
                      let from = (animation.fromValue as? NSValue)?.cgPointValue,
                      let to = (animation.toValue as? NSValue)?.cgPointValue,
                      from.y != to.y, now < animation.beginTime + animation.duration else { continue }
                let displacement = (current.presentation()?.position.y ?? current.position.y) - current.position.y
                return KeyboardSpring(
                    animation: animation,
                    id: .init(layer: ObjectIdentifier(current), key: key, beginTime: animation.beginTime),
                    from: from.y, to: to.y, displacement: displacement
                )
            }
            layer = current.superlayer
        }
        return nil
    }

    /// The lowest visible composer.
    private func findComposer(in window: UIWindow) -> ComposerKeyboardAnchorView? {
        var best: (view: ComposerKeyboardAnchorView, maxY: CGFloat)?
        func visit(_ view: UIView) {
            guard !view.isHidden, view.alpha > 0.01 else { return }
            if let anchor = view as? ComposerKeyboardAnchorView, !anchor.bounds.isEmpty {
                let maxY = anchor.convert(anchor.bounds, to: window).maxY
                if maxY <= window.bounds.maxY, maxY > (best?.maxY ?? -.infinity) {
                    best = (anchor, maxY)
                }
                return
            }
            view.subviews.forEach(visit)
        }
        visit(window)
        return best?.view
    }
}

private extension UIView {
    /// Hidden itself or through an ancestor.
    var isHiddenInWindow: Bool {
        var view: UIView? = self
        while let current = view {
            if current.isHidden || current.alpha < 0.01 { return true }
            view = current.superview
        }
        return false
    }
}

/// The display link's target, which only needs to wake the run loop.
private final class FrameTickTarget: NSObject {
    static let shared = FrameTickTarget()

    @objc func tick() {}
}
