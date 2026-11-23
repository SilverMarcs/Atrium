import Foundation

public struct AgentUsageWindow: Identifiable {
    public let id: String
    public let title: String
    public let usedPercent: Double
    public var resetsAt: Date?
}
