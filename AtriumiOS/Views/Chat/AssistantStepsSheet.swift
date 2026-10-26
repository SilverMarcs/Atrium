import SwiftUI

/// Every step behind a reply, in order: the agent's notes as plain text and its
/// tool calls as one-line summaries, set smaller than the reply itself.
struct AssistantStepsSheet: View {
    let steps: [TranscriptBlock]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(steps) { step in
                Group {
                    switch step.kind {
                    case .text:
                        Label {
                            Text(step.text)
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                        } icon: {
                            Image(systemName: "text.alignleft")
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    case .tool:
                        Label {
                            Text(step.toolName ?? "Tool")
                                .font(.subheadline)
                            Text(step.text)
                                .font(.caption.monospaced())
                                .lineLimit(1)
                        } icon: {
                            Image(systemName: step.symbolName)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .listRowSeparator(.hidden, edges: .top)
                .listRowSeparator(.visible, edges: .bottom)
            }
            .listStyle(.inset)
            .navigationTitle(steps.count == 1 ? "1 Step" : "\(steps.count) Steps")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .close) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
