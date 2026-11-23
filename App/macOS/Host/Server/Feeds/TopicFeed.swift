import Foundation

/// The state behind one topic, kept current on the host while any client
/// follows it. Feeds publish whole states; each connection turns them into the
/// changes its client hasn't seen yet.
@MainActor
protocol TopicFeed: AnyObject {
    /// The state a new subscriber starts from, once there is any.
    var current: HostEvent? { get }
    func start(publish: @escaping (HostEvent) -> Void)
    func stop()
    /// A client subscribed again; feeds that can be stale reload.
    func refresh()
}

extension TopicFeed {
    func refresh() {}
}
