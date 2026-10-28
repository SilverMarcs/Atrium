import SwiftUI

/// Every step behind a reply, in order: the agent's notes as plain text and each
/// run of tool calls as its count, set smaller than the reply itself.
struct AssistantStepsSheet: View {
    let steps: [TranscriptBlock]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(steps) { step in
                AssistantStepRow(step: step)
                .listRowSeparator(.hidden, edges: .top)
                .listRowSeparator(.visible, edges: .bottom)
            }
            .listStyle(.inset)
            .navigationTitle("Steps")
            #if os(iOS)
            .toolbarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(width: 480, height: 480)
        #else
        .presentationDetents([.medium, .large])
        #endif
    }
}
