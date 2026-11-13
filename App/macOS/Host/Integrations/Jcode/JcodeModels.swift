import AtriumProtocol
import Foundation

/// The models Jcode can run, as its runtime info lists them: every one a
/// login Jcode has reaches, however it was signed in. Each is selected by its
/// name, and Jcode picks the route from its own logins.
nonisolated enum JcodeModels {
    /// Jcode accepts every reasoning effort for every model, and doesn't list a
    /// model's own. These are the ones OpenAI's and Anthropic's current models take.
    private static let efforts = ["OpenAI": ["low", "medium", "high", "xhigh"], "Anthropic": ["low", "medium", "high"]]

    static func models(fromRoutes routes: [[String: Any]]) -> [AgentModel] {
        var seen: Set<String> = []
        return routes.compactMap { route in
            guard route["available"] as? Bool == true, let model = route["model"] as? String,
                  seen.insert(model).inserted else { return nil }
            let provider = route["provider"] as? String ?? ""
            return AgentModel(
                id: model, resolvedID: model, name: name(of: model), summary: provider,
                reasoningEfforts: efforts[provider] ?? [],
                // Jcode's fast mode is OpenAI's priority tier.
                supportsFastMode: provider == "OpenAI",
                // Jcode runs every tool without asking: it has no approvals to answer.
                permissionModes: [.fullAccess]
            )
        }
    }

    /// "gpt-5.6-terra" as "GPT-5.6 Terra", and "claude-opus-5-5" as "Claude Opus 5.5".
    static func name(of model: String) -> String {
        var words: [String] = []
        var version: [String] = []
        for part in model.split(separator: "-").map(String.init) {
            if part.allSatisfy(\.isNumber) { version.append(part); continue }
            if !version.isEmpty { words.append(version.joined(separator: ".")); version = [] }
            words.append(part == "gpt" ? "GPT" : part.prefix(1).uppercased() + part.dropFirst())
        }
        if !version.isEmpty { words.append(version.joined(separator: ".")) }
        if words.first == "GPT", words.count > 1 { words[0...1] = ["GPT-" + words[1]] }
        return words.joined(separator: " ")
    }
}

/// What `jcode usage` reports of the subscriptions Jcode signed in to.
@MainActor
enum JcodeUsageReader {
    static func read() async throws -> AgentUsageSnapshot {
        let data = try await IntegrationProcess.run("jcode", arguments: ["--no-update", "usage", "--json"], timeout: .seconds(30))
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let providers = result["providers"] as? [[String: Any]] else {
            throw IntegrationError(message: "Jcode returned invalid usage.")
        }
        let formatter = ISO8601DateFormatter()
        var windows: [AgentUsageWindow] = []
        var plans: [String] = []
        for provider in providers where provider["error"] == nil || provider["error"] is NSNull {
            let name = provider["provider_name"] as? String ?? "Jcode"
            for limit in provider["limits"] as? [[String: Any]] ?? [] {
                guard let title = limit["name"] as? String, let percent = limit["usage_percent"] as? Double else { continue }
                windows.append(AgentUsageWindow(
                    id: "\(name).\(title)", title: "\(name) · \(title)", usedPercent: percent,
                    resetsAt: (limit["resets_at"] as? String).flatMap(formatter.date(from:))))
            }
            let info = provider["extra_info"] as? [[String]] ?? []
            if let plan = info.first(where: { $0.first == "Plan" })?.last { plans.append("\(name): \(plan)") }
        }
        return AgentUsageSnapshot(
            status: providers.isEmpty ? "Not signed in" : "Signed in", plan: plans.isEmpty ? nil : plans.joined(separator: ", "),
            windows: windows, usageMessage: windows.isEmpty ? "Unavailable" : nil)
    }
}
