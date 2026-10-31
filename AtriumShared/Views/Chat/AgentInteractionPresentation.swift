import AtriumProtocol
import SwiftUI

/// Presents the oldest pending request and keeps it available after dismissing
/// it. An approval is a native alert naming what the agent wants to do; a
/// question opens a sheet to answer it in.
struct AgentInteractionPresentation: ViewModifier {
    let requests: [AgentInteraction]
    let respond: (AgentInteraction, AgentDecision) async throws -> Void
    var canPresent = true
    var prepareToPresent: () -> Void = {}
    @State private var presented: AgentInteraction?
    @State private var alerted: AgentInteraction?
    @State private var error: String?

    func body(content: Content) -> some View {
        content
            .toolbar {
                if let request = requests.first {
                    ToolbarItem {
                        Button("Review Request", systemImage: "questionmark.bubble") { present(request) }
                            .disabled(!canPresent)
                    }
                }
            }
            .onChange(of: requests.first, initial: true) { _, request in present(request) }
            .onChange(of: canPresent) { _, available in
                if available { present(requests.first) }
            }
            .sheet(item: $presented) { request in
                AgentInteractionSheet(request: request, respond: { decision in
                    try await respond(request, decision)
                })
                .id(request.id)
            }
            .alert(
                alerted?.title ?? "",
                isPresented: Binding(get: { alerted != nil }, set: { if !$0 { alerted = nil } }),
                presenting: alerted
            ) { request in
                if request.supportsResponse {
                    Button("Allow", role: .confirm) { submit(AgentDecision(allowed: true), to: request) }
                    Button("Decline", role: .destructive) { submit(AgentDecision(allowed: false), to: request) }
                    // Leaves it pending; Review Request in the toolbar brings it back.
                    Button("Not Now", role: .cancel) {}
                } else {
                    Button("OK", role: .cancel) {}
                }
            } message: { request in
                Text(Self.summary(of: request.detail))
            }
            .alert("Couldn’t Send Response", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) { error = nil }
            } message: {
                Text(error ?? "")
            }
    }

    private func present(_ request: AgentInteraction?) {
        guard let request else {
            presented = nil
            alerted = nil
            return
        }
        guard canPresent else { return }
        prepareToPresent()
        if request.questions.isEmpty {
            presented = nil
            alerted = request
        } else {
            alerted = nil
            presented = request
        }
    }

    private func submit(_ decision: AgentDecision, to request: AgentInteraction) {
        Task {
            do { try await respond(request, decision) }
            catch { self.error = error.localizedDescription }
        }
    }

    /// Enough of the request to recognize it, never a whole diff: what a tool's
    /// input says it does (Claude sends the input as JSON), else its first line.
    private static func summary(of detail: String) -> String {
        var line = detail.split(whereSeparator: \.isNewline).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map(String.init) ?? ""
        if let input = (try? JSONSerialization.jsonObject(with: Data(detail.utf8))) as? [String: Any],
           let described = ["description", "command", "file_path", "path", "url", "prompt"].lazy.compactMap({ input[$0] as? String }).first {
            line = described
        }
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > 160 ? trimmed.prefix(160) + "…" : trimmed
    }
}
