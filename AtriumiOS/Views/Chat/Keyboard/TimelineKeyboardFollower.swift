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
/// Both the composer and the timeline's offset are set on the main thread
/// before each Core Animation commit. Just before the commit, this draws the
/// timeline at the offset that matches the composer's progress, with a held
/// additive `bounds.origin` offset over whatever SwiftUI set. The scroll view's
/// real offset is left to SwiftUI, so scrolling state and hit testing are
/// unchanged once the move ends.
///
/// The composer sits a fixed distance above the safe area's edge, so it
/// travels exactly as far as the safe area changes. That ties the two together
/// without knowing the keyboard's height.
@MainActor
final class TimelineKeyboardFollower {
    private struct Follow {
        let isShowing: Bool
        /// The composer's top edge and the timeline's safe area and offset
        /// when the move began.
        let startY: CGFloat
        let startSafeAreaBottom: CGFloat
        let startOffset: CGFloat
        /// The safe area the timeline ends with.
        var endSafeAreaBottom: CGFloat
        let startTime: CFTimeInterval
        /// The timeline's safe area in the last pass, and when it last changed.
        var safeAreaBottom: CGFloat
        var safeAreaChangedAt: CFTimeInterval
        var progress: CGFloat = 0
        /// The additive offset drawn in the last commit.
        var additive: CGFloat = 0

        var endY: CGFloat {
            startY - (endSafeAreaBottom - startSafeAreaBottom)
        }
    }

    /// The key UIKit animates scroll offset corrections under.
    private static let systemAnimationKey = "bounds.origin"
    private static let animationKey = "atrium.keyboardFollow"
    /// Ends a follow whose composer or timeline never settles.
    private static let maximumDuration: CFTimeInterval = 1
    /// How long the safe area must hold still to count as settled. Passes can
    /// run several times within one frame, so the safe area matching the
    /// previous pass doesn't mean SwiftUI has finished animating it.
    private static let safeAreaSettleDuration: CFTimeInterval = 0.05

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
    /// The newest message's offset in the previous pass. Sending adds a row in
    /// the same turn the keyboard starts hiding, so the current content size
    /// can't tell whether the timeline was pinned before.
    private var lastMaximumOffset: CGFloat?
    private var follow: Follow?
    /// Ends a follow whose passes stopped before it did.
    private var timeout: Task<Void, Never>?
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
            // UIKit can replace the bottom-bar search field during a focus
            // transition. Its temporary absence must not disable following.
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
            updateFollow(in: scrollView, composerY: y)
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
    /// Runs before either moves. `ScrollOnComposerFocus` takes the timeline
    /// to its newest message, so it follows from anywhere near it.
    private func beginShowFollowIfNeeded() {
        guard let scrollView, scrollView.window != nil, !scrollView.isTracking,
              composerY() != nil, let restY = restingComposerY,
              let restingSafeAreaBottom,
              maximumOffset(of: scrollView, safeAreaBottom: restingSafeAreaBottom) - scrollView.contentOffset.y < scrollView.bounds.height else { return }
        // The safe area may already have grown for the keyboard.
        let now = CACurrentMediaTime()
        startFollow(Follow(isShowing: true, startY: restY, startSafeAreaBottom: restingSafeAreaBottom,
                           startOffset: scrollView.contentOffset.y,
                           endSafeAreaBottom: max(scrollView.safeAreaInsets.bottom, restingSafeAreaBottom),
                           startTime: now, safeAreaBottom: scrollView.safeAreaInsets.bottom,
                           safeAreaChangedAt: now), in: scrollView)
    }

    /// Starts following as the keyboard hides, under a timeline that was
    /// pinned to its newest message, with the composer still above its
    /// resting place. Uses the previous pass, from before anything moved.
    private func beginHideFollowIfNeeded(in scrollView: UIScrollView, composerY y: CGFloat) {
        guard let startY = lastComposerY, let startSafeAreaBottom = lastSafeAreaBottom,
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
        startFollow(Follow(isShowing: false, startY: startY, startSafeAreaBottom: startSafeAreaBottom,
                           startOffset: startOffset, endSafeAreaBottom: endSafeAreaBottom,
                           startTime: now, safeAreaBottom: safeAreaBottom,
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
        timeout?.cancel()
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.maximumDuration))
            guard !Task.isCancelled else { return }
            self?.endFollow(settling: true)
        }
    }

    private func updateFollow(in scrollView: UIScrollView, composerY y: CGFloat) {
        guard var follow else { return }
        let safeAreaBottom = scrollView.safeAreaInsets.bottom
        if follow.isShowing {
            follow.endSafeAreaBottom = max(follow.endSafeAreaBottom, safeAreaBottom)
        }
        let travel = follow.endY - follow.startY
        follow.progress = abs(travel) < 1 ? 0 : min(max((y - follow.startY) / travel, 0), 1)
        // The field UIKit rests the composer in after a send sits up to a point
        // off the one it rested in before, so arriving within two points counts.
        // Otherwise the follow only ends when it times out.
        if abs(y - follow.endY) < 2 {
            follow.progress = 1
        }
        // Once the composer has arrived, end where SwiftUI's safe area does,
        // in case the estimate was a point or two out. The safe area can still
        // be animating well after the composer arrives; ending then would
        // drop the timeline back to SwiftUI's offset, above where it settles,
        // and it would bounce up before following the safe area down.
        let now = CACurrentMediaTime()
        if safeAreaBottom != follow.safeAreaBottom {
            follow.safeAreaBottom = safeAreaBottom
            follow.safeAreaChangedAt = now
        }
        let isSafeAreaSettled = now - follow.safeAreaChangedAt >= Self.safeAreaSettleDuration
        if follow.progress >= 1, isSafeAreaSettled {
            follow.endSafeAreaBottom = safeAreaBottom
        }
        self.follow = follow
        applyFollow(to: scrollView)

        let endOffset = maximumOffset(of: scrollView, safeAreaBottom: follow.endSafeAreaBottom)
        if follow.progress >= 1, isSafeAreaSettled, abs(scrollView.contentOffset.y - endOffset) < 0.5 {
            endFollow(settling: true)
        } else if scrollView.isTracking
            || now - follow.startTime > Self.maximumDuration {
            // A new touch, or a move that never settled, hands the rest to an animation.
            endFollow(settling: true)
        }
    }

    /// Draws the timeline at the offset matching the composer's progress.
    private func applyFollow(to scrollView: UIScrollView) {
        guard var follow else { return }
        let endOffset = maximumOffset(of: scrollView, safeAreaBottom: follow.endSafeAreaBottom)
        let target = follow.startOffset + (endOffset - follow.startOffset) * follow.progress
        let additive = target - scrollView.contentOffset.y
        let layer = scrollView.layer
        // UIKit's own correction would add to this one.
        layer.removeAnimation(forKey: Self.systemAnimationKey)
        guard abs(additive - follow.additive) > 0.01 || layer.animation(forKey: Self.animationKey) == nil else { return }
        follow.additive = additive
        self.follow = follow
        layer.add(heldOffset(additive, keyPath: Self.systemAnimationKey), forKey: Self.animationKey)
        // Holding them in place draws them where UIKit already has them.
        for view in pinnedSubviews(of: scrollView) {
            view.layer.add(heldOffset(additive, keyPath: "position"), forKey: Self.animationKey)
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
        timeout?.cancel()
        timeout = nil
        guard let scrollView else { return }
        let layers = [(scrollView.layer, Self.systemAnimationKey)]
            + pinnedSubviews(of: scrollView).map { ($0.layer, "position") }
        for (layer, keyPath) in layers {
            layer.removeAnimation(forKey: Self.animationKey)
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

    /// The composer's top edge in window coordinates, from the model layer:
    /// where it is drawn in the coming commit.
    private func composerY() -> CGFloat? {
        // Search presentation swaps visible fields without necessarily
        // removing the previous one from its window. Resolve the current
        // composer for this commit instead of retaining a stale clone.
        guard let window = scrollView?.window, let composer = findComposer(in: window) else { return nil }
        return composer.convert(composer.bounds, to: window).minY
    }

    /// The lowest visible search field: the composer UIKit draws in the
    /// bottom bar, which follows the keyboard.
    private func findComposer(in window: UIWindow) -> UIView? {
        var best: (view: UIView, maxY: CGFloat)?
        func visit(_ view: UIView) {
            guard !view.isHidden, view.alpha > 0.01 else { return }
            if let field = view as? UISearchTextField, field.leftView is ComposerSearchFieldStyle,
               !field.bounds.isEmpty {
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
