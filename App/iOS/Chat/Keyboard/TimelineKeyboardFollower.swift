import UIKit

/// Moves a timeline pinned to its newest message with the composer as the
/// keyboard shows and hides, instead of on a clock of its own.
///
/// The composer follows the keyboard's spring, but the timeline's offset
/// doesn't:
/// - Hiding, SwiftUI animates the keyboard safe area frame by frame on a
///   slower curve, so the timeline trails the composer by up to ~170pt and is
///   still falling after the composer has settled. (When an interactive
///   dismissal stalls the main thread, the safe area instead collapses in one
///   step and UIKit animates the correction with a late 0.18s `bounds.origin`
///   animation.)
/// - Showing, the safe area grows in one step and the timeline only moves
///   when `ScrollOnComposerFocus` scrolls to the newest message on an
///   ease-out curve, so the composer first runs ahead of the timeline and
///   then covers it.
///
/// SwiftUI moves the composer with the keyboard in a Core Animation spring,
/// on the composer's container, while the timeline's safe area and offset
/// change in one step. This copies that spring onto the timeline's
/// `bounds.origin`, so the render server moves both on the same clock, and
/// holds an additive offset, set before each Core Animation commit, for the
/// rest: the timeline kept at its end above wherever SwiftUI has the composer
/// in that frame, as it grows or shrinks. The scroll view's real offset is left
/// to SwiftUI, so scrolling state and hit testing are unchanged once the move
/// ends.
@MainActor
final class TimelineKeyboardFollower {
    private struct Follow {
        let isShowing: Bool
        let startTime: CFTimeInterval
        /// The timeline's safe area in the last pass, and when it last changed.
        var safeAreaBottom: CGFloat
        var safeAreaChangedAt: CFTimeInterval
        /// The held additive offset drawn in the last commit.
        var additive: CGFloat = 0
        /// The composer's keyboard animation the timeline mirrors, by its
        /// layer, key and start.
        var mirrored: MirroredAnimation?
    }

    private struct MirroredAnimation: Equatable {
        let layer: ObjectIdentifier
        let key: String
        let beginTime: CFTimeInterval
    }

    /// The key UIKit animates scroll offset corrections under.
    private static let systemAnimationKey = "bounds.origin"
    private static let animationKey = "atrium.keyboardFollow"
    private static let mirrorKey = "atrium.keyboardFollow.spring"
    /// Ends a follow whose composer or timeline never settles.
    private static let maximumDuration: CFTimeInterval = 1
    /// How long the safe area must hold still to count as settled. Passes can
    /// run several times within one frame, so the safe area matching the
    /// previous pass doesn't mean SwiftUI has finished animating it.
    private static let safeAreaSettleDuration: CFTimeInterval = 0.05

    /// Whether the timeline keeps its end above the composer: pinned there,
    /// rather than scrolled back by the reader or holding a prompt at the
    /// top. Otherwise the keyboard moves over a timeline that stays put, so
    /// there's nothing to follow.
    var followsLatest: () -> Bool = { true }
    private weak var scrollView: UIScrollView?
    private var observer: CFRunLoopObserver?
    private var offsetObservation: NSKeyValueObservation?
    private var notificationTokens: [any NSObjectProtocol] = []
    /// Where the composer rests with the keyboard hidden: the lowest it has
    /// been in a viewport of this size.
    private var restingComposerY: CGFloat?
    private var restingViewportSize: CGSize?
    /// The timeline's safe area while the composer rests.
    private var restingSafeAreaBottom: CGFloat?
    /// The previous pass, from just before a dismissal begins.
    private var lastComposerY: CGFloat?
    private var lastSafeAreaBottom: CGFloat?
    private var lastOffset: CGFloat?
    /// The newest message's offset in the previous pass. Content can grow in
    /// the same turn the keyboard starts hiding, so the current content size
    /// can't tell whether the timeline was pinned before.
    private var lastMaximumOffset: CGFloat?
    private var follow: Follow?
    /// Ends a follow whose passes stopped before it did.
    private var timeout: Task<Void, Never>?
    /// Wakes the main run loop every frame while following. The composer
    /// rides the keyboard in a Core Animation animation, with nothing else
    /// necessarily running on the main thread to draw the timeline along.
    private var frameTicker: CADisplayLink?
    private var isKeyboardVisible = false
    /// UIKit announced that the keyboard is hiding. Until then, a shrinking
    /// safe area can also be the keyboard changing height.
    private var isHideAnnounced = false
    /// One drop per dismissal.
    private var hasFollowedThisDismissal = false
    /// Keeps watching briefly after the keyboard hides, since the drop can
    /// start after `keyboardDidHide`.
    private var watchUntil: CFTimeInterval = 0

    func attach(to scrollView: UIScrollView) {
        if self.scrollView === scrollView, !notificationTokens.isEmpty {
            if !isKeyboardVisible, !isHideAnnounced, follow == nil, let y = composerY() {
                noteComposerAtRest(y, in: scrollView)
            }
            return
        }
        detach()
        self.scrollView = scrollView
        if let window = scrollView.window {
            isKeyboardVisible = window.keyboardLayoutGuide.layoutFrame.height > window.safeAreaInsets.bottom + 1
        }
        if !isKeyboardVisible, let y = composerY() {
            noteComposerAtRest(y, in: scrollView)
        }
        // The toolbar and safe area may not have laid out yet. Observe their
        // first commits rather than relying on the representable's creation.
        watchUntil = CACurrentMediaTime() + 0.6
        startObserving()

        let center = NotificationCenter.default
        notificationTokens = [
            center.addObserver(forName: UIResponder.keyboardWillShowNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.keyboardWillShow() }
            },
            center.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.keyboardWillHide() }
            },
            center.addObserver(forName: UIResponder.keyboardDidHideNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.keyboardDidHide() }
            },
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
        isKeyboardVisible = false
        isHideAnnounced = false
        hasFollowedThisDismissal = false
        restingComposerY = nil
        restingSafeAreaBottom = nil
        restingViewportSize = nil
        scrollView = nil
    }

    private func keyboardWillShow() {
        let wasVisible = isKeyboardVisible
        isKeyboardVisible = true
        isHideAnnounced = false
        hasFollowedThisDismissal = false
        startObserving()
        // A second announcement while the keyboard is up is a size change,
        // with no resting composer to start from.
        if !wasVisible, follow == nil {
            beginShowFollowIfNeeded()
        }
    }

    private func keyboardWillHide() {
        isKeyboardVisible = false
        isHideAnnounced = true
        watchUntil = CACurrentMediaTime() + 0.6
        startObserving()
        if follow?.isShowing == true {
            endFollow(settling: true)
        }
        // Closing the composer, UIKit can collapse the safe area in one step
        // and commit the clamped offset before another pass runs, which draws
        // one frame of the timeline already settled under the raised composer.
        // Starting now, while nothing has moved, lets the offset observation
        // hold the timeline in place within that same commit.
        if follow == nil, !hasFollowedThisDismissal, let scrollView, scrollView.window != nil,
           let y = composerY() {
            beginHideFollowIfNeeded(in: scrollView, composerY: y)
        }
    }

    private func keyboardDidHide() {
        isKeyboardVisible = false
        isHideAnnounced = false
        watchUntil = CACurrentMediaTime() + 0.6
        startObserving()
    }

    // MARK: - Resting place

    /// Records where the composer and safe area rest, once the composer is
    /// back at the bottom.
    private func noteComposerAtRest(_ y: CGFloat, in scrollView: UIScrollView) {
        let viewportSize = scrollView.window?.bounds.size ?? scrollView.bounds.size
        if restingViewportSize != viewportSize {
            restingViewportSize = viewportSize
            restingComposerY = nil
            restingSafeAreaBottom = nil
        }
        if y >= (restingComposerY ?? -.infinity) - 0.5 {
            restingComposerY = max(y, restingComposerY ?? y)
            // Zero before the first layout; the bottom bar always takes some.
            if scrollView.safeAreaInsets.bottom > 0 {
                restingSafeAreaBottom = scrollView.safeAreaInsets.bottom
            }
        }
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
        lastComposerY = nil
        lastSafeAreaBottom = nil
        lastOffset = nil
        lastMaximumOffset = nil
    }

    private func beforeCommit() {
        guard let scrollView, scrollView.window != nil else {
            endFollow(settling: false)
            stopObserving()
            return
        }
        guard let y = composerY() else {
            // The composer can be missing for a moment while its screen is
            // pushed or popped. Its absence must not disable following.
            if CACurrentMediaTime() > watchUntil, !isKeyboardVisible {
                endFollow(settling: false)
                stopObserving()
            }
            return
        }
        if !isKeyboardVisible, follow == nil, !isHideAnnounced || restingComposerY != nil {
            noteComposerAtRest(y, in: scrollView)
        }
        if follow == nil, !hasFollowedThisDismissal {
            beginHideFollowIfNeeded(in: scrollView, composerY: y)
        }
        if follow != nil {
            updateFollow(in: scrollView)
        } else if !isKeyboardVisible, CACurrentMediaTime() > watchUntil {
            stopObserving()
            return
        }
        lastComposerY = y
        lastSafeAreaBottom = scrollView.safeAreaInsets.bottom
        lastOffset = scrollView.contentOffset.y
        lastMaximumOffset = maximumOffset(of: scrollView, safeAreaBottom: scrollView.safeAreaInsets.bottom)
    }

    // MARK: - Following

    /// Starts following as the keyboard shows, with the composer at rest.
    /// Runs before either moves. `ScrollOnComposerFocus` takes a pinned
    /// timeline to its newest message, so it follows from anywhere near it.
    private func beginShowFollowIfNeeded() {
        // The safe area has usually grown for the keyboard already.
        guard followsLatest(), let scrollView, scrollView.window != nil, !scrollView.isTracking,
              composerY() != nil,
              endOffset(of: scrollView) - scrollView.contentOffset.y < scrollView.bounds.height else { return }
        let now = CACurrentMediaTime()
        startFollow(Follow(isShowing: true, startTime: now, safeAreaBottom: scrollView.safeAreaInsets.bottom,
                           safeAreaChangedAt: now), in: scrollView)
    }

    /// Starts following as the keyboard hides, under a timeline that was
    /// pinned to its newest message, with the composer still above its
    /// resting place. Uses the previous pass, from before anything moved.
    private func beginHideFollowIfNeeded(in scrollView: UIScrollView, composerY y: CGFloat) {
        guard followsLatest(), let startY = lastComposerY, let startSafeAreaBottom = lastSafeAreaBottom,
              let startOffset = lastOffset, let startMaximumOffset = lastMaximumOffset,
              let restY = restingComposerY,
              restY - startY > 1 else { return }
        // The composer's way down is the safe area's.
        let endSafeAreaBottom = startSafeAreaBottom - (restY - startY)
        let safeAreaBottom = scrollView.safeAreaInsets.bottom
        // Hiding once UIKit says so, or when the safe area collapses all the
        // way at once (an interactive dismissal can do that first). Shrinking
        // part of the way, with the keyboard still up, is a size change.
        let isHiding = isHideAnnounced || abs(safeAreaBottom - endSafeAreaBottom) < 2
        guard isHiding, safeAreaBottom < startSafeAreaBottom - 0.5 || isHideAnnounced else { return }
        guard !scrollView.isTracking, !scrollView.isDragging, !scrollView.isDecelerating,
              abs(startOffset - startMaximumOffset) < 2 else { return }
        hasFollowedThisDismissal = true
        let now = CACurrentMediaTime()
        startFollow(Follow(isShowing: false, startTime: now, safeAreaBottom: safeAreaBottom,
                           safeAreaChangedAt: now), in: scrollView)
    }

    private func startFollow(_ follow: Follow, in scrollView: UIScrollView) {
        self.follow = follow
        // SwiftUI may set the offset again after a pass, as layout runs.
        offsetObservation = scrollView.observe(\.contentOffset) { [weak self] scrollView, _ in
            MainActor.assumeIsolated { self?.applyFollow(to: scrollView) }
        }
        applyFollow(to: scrollView)
        // Passes only run when the main run loop wakes. After a send, nothing may
        // wake it until the host answers, which would leave the timeline drawn at
        // the held offset: away from where the lazy rows are built, so it shows
        // blank until a touch ends the follow.
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
        }
        let spring = keyboardAnimation(above: composer)
        if let spring, follow.mirrored != spring.id {
            mirror(spring, in: scrollView)
            follow.mirrored = spring.id
        }
        self.follow = follow
        applyFollow(to: scrollView)

        let isSafeAreaSettled = now - follow.safeAreaChangedAt >= Self.safeAreaSettleDuration
        if spring == nil, isSafeAreaSettled, abs(composerDisplacement(of: composer)) < 0.5, abs(follow.additive) < 0.5 {
            endFollow(settling: true)
        } else if scrollView.isTracking || now - follow.startTime > Self.maximumDuration {
            // A new touch, or a move that never settled, hands the rest to an animation.
            endFollow(settling: true)
        }
    }

    /// Holds the timeline at its end above where SwiftUI has the composer in
    /// this commit. The keyboard's spring is mirrored separately; anything
    /// else moving the composer only shows here, a frame late.
    private func applyFollow(to scrollView: UIScrollView) {
        guard var follow else { return }
        var unmirrored: CGFloat = 0
        var layoutLag: CGFloat = 0
        if let composer = currentComposer(), let window = scrollView.window {
            unmirrored = composerDisplacement(of: composer) - (keyboardAnimation(above: composer)?.displacement ?? 0)
            // SwiftUI gives the timeline the composer's new height at once,
            // and animates the composer to it frame by frame.
            let safeAreaEdge = scrollView.convert(scrollView.bounds, to: window).maxY - scrollView.safeAreaInsets.bottom
            layoutLag = composer.convert(composer.bounds, to: window).minY - safeAreaEdge
        }
        let additive = endOffset(of: scrollView) - scrollView.contentOffset.y - layoutLag - unmirrored
        let layer = scrollView.layer
        // UIKit's own corrections would add to this one.
        for key in layer.animationKeys() ?? [] where key.hasPrefix(Self.systemAnimationKey) {
            layer.removeAnimation(forKey: key)
        }
        guard abs(additive - follow.additive) > 0.01 || layer.animation(forKey: Self.animationKey) == nil else { return }
        follow.additive = additive
        self.follow = follow
        layer.add(heldOffset(additive, keyPath: Self.systemAnimationKey), forKey: Self.animationKey)
        // Holding them in place draws them where UIKit already has them.
        for view in pinnedSubviews(of: scrollView) {
            view.layer.add(heldOffset(additive, keyPath: "position"), forKey: Self.animationKey)
        }
    }

    /// Copies the composer's keyboard spring onto the timeline, inverted: the
    /// composer drawn lower than its model means the timeline's end is too.
    private func mirror(_ spring: KeyboardAnimation, in scrollView: UIScrollView) {
        guard let copy = spring.animation.copy() as? CABasicAnimation else { return }
        copy.isAdditive = true
        copy.fromValue = NSValue(cgPoint: CGPoint(x: 0, y: -spring.from))
        copy.toValue = NSValue(cgPoint: CGPoint(x: 0, y: -spring.to))
        copy.isRemovedOnCompletion = true
        copy.keyPath = Self.systemAnimationKey
        scrollView.layer.add(copy, forKey: Self.mirrorKey)
        for view in pinnedSubviews(of: scrollView) {
            guard let pinned = copy.copy() as? CABasicAnimation else { continue }
            pinned.keyPath = "position"
            view.layer.add(pinned, forKey: Self.mirrorKey)
        }
    }

    /// UIKit's chrome inside the scroll view, which it keeps fixed to the
    /// viewport: the scroll edge effects behind the toolbars, and the scroll
    /// indicators. Offsetting the scroll view's bounds moves them with the
    /// content, so the top toolbar's backdrop would jump.
    private func pinnedSubviews(of scrollView: UIScrollView) -> [UIView] {
        scrollView.subviews.filter { NSStringFromClass(type(of: $0)).hasPrefix("_UI") }
    }

    /// The offset that shows the newest message above a bottom safe area.
    private func maximumOffset(of scrollView: UIScrollView, safeAreaBottom: CGFloat) -> CGFloat {
        scrollView.contentSize.height - scrollView.bounds.height + scrollView.contentInset.bottom + safeAreaBottom
    }

    /// Where a timeline kept at its end rests above the current safe area,
    /// or its top when it's shorter than the view.
    private func endOffset(of scrollView: UIScrollView) -> CGFloat {
        max(maximumOffset(of: scrollView, safeAreaBottom: scrollView.safeAreaInsets.bottom), -scrollView.adjustedContentInset.top)
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
            // A touch takes over mid-spring.
            if !settling || scrollView.isTracking { layer.removeAnimation(forKey: Self.mirrorKey) }
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

    /// The composer's top edge in window coordinates, where it's drawn: it
    /// rides the keyboard in a Core Animation animation, so its model layer
    /// is already where it ends up.
    private func composerY() -> CGFloat? {
        guard let window = scrollView?.window, let composer = currentComposer() else { return nil }
        guard let presented = composer.layer.presentation() else {
            return composer.convert(composer.bounds, to: window).minY
        }
        // Presentation layers convert through their presented ancestors.
        return presented.convert(presented.bounds, to: nil).minY
    }

    /// A screen kept behind the task list can leave its composer in the
    /// window, so the one in view is resolved for each commit.
    private func currentComposer() -> UIView? {
        guard let window = scrollView?.window else { return nil }
        return findComposer(in: window)
    }

    /// How far below its model position the composer is drawn.
    private func composerDisplacement(of composer: UIView) -> CGFloat {
        guard let window = composer.window, let presented = composer.layer.presentation() else { return 0 }
        return presented.convert(presented.bounds, to: nil).minY - composer.convert(composer.bounds, to: window).minY
    }

    private struct KeyboardAnimation {
        let animation: CABasicAnimation
        let id: MirroredAnimation
        /// The additive vertical offset it runs from and to.
        let from: CGFloat
        let to: CGFloat
        /// Its offset in the frame on screen now.
        let displacement: CGFloat
    }

    /// The additive position animation SwiftUI moves the composer's container
    /// with as the keyboard shows or hides, while it runs.
    private func keyboardAnimation(above composer: UIView) -> KeyboardAnimation? {
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
                return KeyboardAnimation(
                    animation: animation,
                    id: MirroredAnimation(layer: ObjectIdentifier(current), key: key, beginTime: animation.beginTime),
                    from: from.y, to: to.y, displacement: displacement
                )
            }
            layer = current.superlayer
        }
        return nil
    }

    /// The lowest visible composer, which follows the keyboard.
    private func findComposer(in window: UIWindow) -> UIView? {
        var best: (view: UIView, maxY: CGFloat)?
        func visit(_ view: UIView) {
            guard !view.isHidden, view.alpha > 0.01 else { return }
            if view is ComposerKeyboardAnchorView, !view.bounds.isEmpty {
                let maxY = view.convert(view.bounds, to: window).maxY
                if maxY <= window.bounds.maxY, maxY > (best?.maxY ?? -.infinity) {
                    best = (view, maxY)
                }
                return
            }
            view.subviews.forEach(visit)
        }
        visit(window)
        return best?.view
    }
}

/// The display link's target, which only needs to wake the run loop.
private final class FrameTickTarget: NSObject {
    static let shared = FrameTickTarget()

    @objc func tick() {}
}
