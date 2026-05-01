import SwiftUI
import AppKit

@MainActor
@Observable
final class QuickPanelController {
    static let shared = QuickPanelController()

    private(set) var chat: Chat
    var isPresented: Bool = false

    @ObservationIgnored private var window: QuickPanelWindow?
    @ObservationIgnored private var hotKey: QuickPanelHotKey?

    private init() {
        self.chat = Self.makeChat()
    }

    func bootstrap() {
        guard hotKey == nil else { return }
        hotKey = QuickPanelHotKey { [weak self] in
            Task { @MainActor in self?.toggle() }
        }
        QuickPanelHotKey.shared = hotKey
    }

    func toggle() {
        if isPresented {
            window?.close()
        } else {
            present()
        }
    }

    private func present() {
        let win = window ?? QuickPanelWindow(controller: self)
        window = win
        isPresented = true
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func didClose() {
        isPresented = false
    }

    /// Disconnects the current session and swaps in a fresh chat so the next
    /// prompt starts a brand new ACP session with whatever provider/model the
    /// user currently has selected as the Quick Panel default.
    func reset() {
        chat.disconnect()
        chat = Self.makeChat()
    }

    /// Update the in-memory chat's provider+model selection. Only valid before
    /// the session has connected (the panel UI hides the picker once it has).
    func selectProviderAndModel(_ provider: AgentProvider, model: String) {
        chat.provider = provider
        chat.model = model
        chat.session.provider = provider
        chat.session.model = model
    }

    private static func makeChat() -> Chat {
        let provider = readProvider()
        let model = readModel(provider: provider)
        return Chat(
            title: "Quick",
            provider: provider,
            permissionMode: .bypassPermissions,
            model: model
        )
    }

    private static func readProvider() -> AgentProvider {
        if let raw = UserDefaults.standard.string(forKey: "quickPanelProvider"),
           let p = AgentProvider(rawValue: raw) { return p }
        if let raw = UserDefaults.standard.string(forKey: "defaultChatMode"),
           let p = AgentProvider(rawValue: raw) { return p }
        return .claude
    }

    private static func readModel(provider: AgentProvider) -> String? {
        if let m = UserDefaults.standard.string(forKey: "quickPanelModel"), !m.isEmpty {
            return m
        }
        return ModelCatalog.shared.defaultModel(for: provider)?.rawValue
    }
}
