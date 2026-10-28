import SwiftUI

/// Presents the oldest pending request and keeps it available after dismissing the sheet.
struct AgentInteractionPresentation: ViewModifier {
    let requests: [AgentInteraction]
    let respond: (AgentInteraction, AgentDecision) async throws -> Void
    var canPresent = true
    var prepareToPresent: () -> Void = {}
    @State private var presented: AgentInteraction?

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
    }

    private func present(_ request: AgentInteraction?) {
        guard let request else { presented = nil; return }
        guard canPresent else { return }
        prepareToPresent()
        presented = request
    }

}
