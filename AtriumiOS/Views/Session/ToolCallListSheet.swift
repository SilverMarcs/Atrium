import SwiftUI

/// Detail sheet for a contiguous tool-call run. One row per call, with a
/// navigation title summarising the count. No drag indicator — sheet
/// still dismisses via swipe-down.
struct ToolCallListSheet: View {
    let tools: [WireBlock]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(tools) { tool in
                Label {
                    Text(tool.text.isEmpty ? "Tool" : tool.text)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } icon: {
                    Image(systemName: tool.toolSymbolName ?? "wrench.and.screwdriver")
                        .foregroundStyle(.secondary)
                }
                .listRowSeparator(.hidden, edges: .top)
                .listRowSeparator(.visible, edges: .bottom)
            }
            .listStyle(.inset)
            .navigationTitle(tools.count == 1 ? "Tool call" : "\(tools.count) tool calls")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .close) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
    }
}
