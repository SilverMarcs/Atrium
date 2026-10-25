import Foundation

/// Accepts companion channels. The server is indifferent to where they come
/// from, so a remote transport only needs another implementation.
@MainActor
protocol CompanionListener: AnyObject {
    var onChannel: ((any CompanionChannel) -> Void)? { get set }
    var onStateChange: ((CompanionListenerState) -> Void)? { get set }

    func start()
    func stop()
}
