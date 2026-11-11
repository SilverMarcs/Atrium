import UIKit

/// Reports each time UIKit attaches it to a window, and again before each
/// Core Animation commit for a moment afterwards. A screen kept alive between
/// visits is reattached on each push, and UIKit builds the new bottom-bar
/// search field during that push's layout passes; checking before every
/// commit styles the field before it's ever drawn.
final class SearchIntrospectionView: UIView {
    var onAttach: (() -> Void)?

    /// How long after attaching to keep checking before each commit.
    private static let watchDuration: CFTimeInterval = 0.5
    private var observer: CFRunLoopObserver?
    private var watchUntil: CFTimeInterval = 0

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else {
            stopObserving()
            return
        }
        watchUntil = CACurrentMediaTime() + Self.watchDuration
        onAttach?()
        startObserving()
    }

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
        guard window != nil, CACurrentMediaTime() < watchUntil else {
            stopObserving()
            return
        }
        onAttach?()
    }
}
