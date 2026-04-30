import Foundation
import Observation
import ACP
import ACPModel

/// In-memory + on-disk catalog of selectable models per provider. Refreshed
/// by spawning a short-lived ACP subprocess per provider, calling `newSession`
/// to read the agent's `models` field, and terminating the subprocess.
///
/// Persisted to `~/Library/Application Support/Atrium/model-catalog.json`
/// keyed by `AgentProvider.rawValue` so we don't have to round-trip a
/// subprocess on every launch.
@MainActor
@Observable
final class ModelCatalog {
    static let shared = ModelCatalog()

    /// `providerRawValue` → models for that provider, in agent-supplied order.
    private(set) var modelsByProvider: [String: [AgentModel]] = [:]
    /// `providerRawValue` → in-flight refresh task, so concurrent refresh
    /// requests dedupe instead of spawning N subprocesses.
    @ObservationIgnored private var inFlight: [String: Task<Void, Never>] = [:]
    /// True while at least one provider refresh is running. Bound to the
    /// settings UI's "Refresh" button to disable during work.
    private(set) var isRefreshing: Bool = false

    @ObservationIgnored private let fileURL: URL

    private init() {
        let fm = FileManager.default
        let appSupport = (try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let dir = appSupport.appendingPathComponent("Atrium", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("model-catalog.json")
        load()
    }

    // MARK: - Public API

    func models(for provider: AgentProvider) -> [AgentModel] {
        modelsByProvider[provider.rawValue] ?? []
    }

    func defaultModel(for provider: AgentProvider) -> AgentModel? {
        models(for: provider).first
    }

    /// Kick off a refresh for any provider with no cached models. Safe to
    /// call on every app launch — providers that already have a non-empty
    /// list are skipped so we don't spawn subprocesses for nothing.
    func bootstrapIfNeeded() {
        for provider in AgentProvider.allCases where models(for: provider).isEmpty {
            startRefresh(provider: provider)
        }
    }

    /// Refresh every provider in parallel. Used by the manual settings button.
    func refreshAll() {
        for provider in AgentProvider.allCases {
            startRefresh(provider: provider)
        }
    }

    /// True while the refresh task for `provider` is running.
    func isRefreshing(provider: AgentProvider) -> Bool {
        inFlight[provider.rawValue] != nil
    }

    /// Harvest the model list from a `configOptionUpdate` carrying the
    /// `model` select. Some agents (notably Gemini) don't include `models`
    /// in their `newSession` response, but they do emit a `configOptionUpdate`
    /// during/after the first prompt. Persisting that harvest means later
    /// app launches see the full list without having to send another prompt.
    func ingestSelect(_ options: SessionConfigSelectOptions, provider: AgentProvider) {
        let flat: [SessionConfigSelectOption]
        switch options {
        case .ungrouped(let opts): flat = opts
        case .grouped(let groups): flat = groups.flatMap(\.options)
        }
        let models = flat.map { opt in
            AgentModel(
                rawValue: opt.value.value,
                name: Self.stripRecommended(opt.name),
                provider: provider
            )
        }
        guard !models.isEmpty else { return }
        if modelsByProvider[provider.rawValue] == models { return }
        modelsByProvider[provider.rawValue] = models
        save()
    }

    // MARK: - Refresh

    private func startRefresh(provider: AgentProvider) {
        if inFlight[provider.rawValue] != nil { return }
        let task = Task { [weak self] in
            guard let self else { return }
            let fetched = await Self.fetchModels(provider: provider)
            await MainActor.run {
                if let fetched, !fetched.isEmpty {
                    self.modelsByProvider[provider.rawValue] = fetched
                    self.save()
                }
                self.inFlight[provider.rawValue] = nil
                self.isRefreshing = !self.inFlight.isEmpty
            }
        }
        inFlight[provider.rawValue] = task
        isRefreshing = true
    }

    /// Spawn a fresh ACP subprocess for `provider`, initialize, create a
    /// throwaway session in the user's home directory, read `models`,
    /// terminate, and return the result.
    private static func fetchModels(provider: AgentProvider) async -> [AgentModel]? {
        let client = Client()
        do {
            let cwd = FileManager.default.homeDirectoryForCurrentUser.path
            try await client.launch(
                agentPath: "/usr/bin/env",
                arguments: ["npx", provider.acpPackage] + provider.acpArgs,
                workingDirectory: cwd
            )
            _ = try await client.initialize(
                capabilities: ClientCapabilities(
                    fs: FileSystemCapabilities(readTextFile: false, writeTextFile: false),
                    terminal: false
                ),
                clientInfo: ClientInfo(
                    name: "Atrium",
                    title: "Swift Terminal",
                    version: "1.0.0"
                ),
                timeout: 120
            )
            let response = try await client.newSession(workingDirectory: cwd, timeout: 60)
            await client.terminate()

            guard let info = response.models else { return nil }
            return info.availableModels.map { m in
                AgentModel(
                    rawValue: m.modelId,
                    name: stripRecommended(m.name),
                    provider: provider
                )
            }
        } catch {
            print("[ModelCatalog] refresh failed for \(provider.rawValue): \(error)")
            await client.terminate()
            return nil
        }
    }

    private static func stripRecommended(_ name: String) -> String {
        // Claude returns names like "Sonnet 4.5 (recommended)". Strip the
        // suffix (case-insensitive, trim trailing whitespace) so the picker
        // shows clean names.
        let pattern = #"\s*\(recommended\)\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return name
        }
        let range = NSRange(name.startIndex..., in: name)
        let cleaned = regex.stringByReplacingMatches(in: name, options: [], range: range, withTemplate: "")
        return cleaned.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Persistence

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            let payload = try JSONDecoder().decode(StorePayload.self, from: data)
            self.modelsByProvider = payload.modelsByProvider
        } catch {
            print("[ModelCatalog] failed to decode \(fileURL.lastPathComponent): \(error)")
        }
    }

    private func save() {
        do {
            let payload = StorePayload(version: 2, modelsByProvider: modelsByProvider)
            let data = try JSONEncoder().encode(payload)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            print("[ModelCatalog] failed to write \(fileURL.lastPathComponent): \(error)")
        }
    }

    private struct StorePayload: Codable {
        let version: Int
        let modelsByProvider: [String: [AgentModel]]
    }
}
