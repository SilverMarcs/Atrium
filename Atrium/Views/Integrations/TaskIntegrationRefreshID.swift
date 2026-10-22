/// Restart the view's refresh task when either provider selection or app activity changes.
struct TaskIntegrationRefreshID: Hashable {
    let providers: [AgentProvider]
    let isActive: Bool
}
