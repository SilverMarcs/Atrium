import Foundation

struct AgentUsageSnapshot {
    var status: String
    var plan: String?
    var windows: [AgentUsageWindow] = []
    var usageMessage: String? = "Unavailable"
}
