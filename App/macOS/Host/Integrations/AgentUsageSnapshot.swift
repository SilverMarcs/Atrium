import Foundation

public struct AgentUsageSnapshot {
    public var status: String
    public var plan: String?
    public var windows: [AgentUsageWindow]
    public var usageMessage: String?

    public init(status: String, plan: String? = nil, windows: [AgentUsageWindow] = [], usageMessage: String? = "Unavailable") {
        self.status = status
        self.plan = plan
        self.windows = windows
        self.usageMessage = usageMessage
    }
}
