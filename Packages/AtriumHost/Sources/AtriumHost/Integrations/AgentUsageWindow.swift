import Foundation

struct AgentUsageWindow: Identifiable {
    let id: String
    let title: String
    let usedPercent: Double
    var resetsAt: Date?
}
