import SwiftUI

/// Keep active-turn geometry stable while questions or approvals wait in a sheet.
/// Once the agent calls a tool, the latest call shows beside the spinner.
struct TaskChatStatusFooter: View {
    let status: AgentThreadStatus
    var toolCall: TranscriptToolCall?

    var body: some View {
        switch status {
        case .processing, .waiting:
            HStack(spacing: 8) {
                ProgressView()
                    #if os(macOS)
                    .controlSize(.small)
                    #endif
                if let toolCall {
                    ToolCallLine(call: toolCall)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        default:
            EmptyView()
        }
    }
}

/// A tool call's name and argument on one line.
private struct ToolCallLine: View {
    let call: TranscriptToolCall
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let argument = call.argument {
                Text("\(call.name) \(Text(argument).foregroundStyle(.secondary))")
            } else {
                Text(call.name)
            }
        }
        .font(.callout)
        .lineLimit(1)
        .truncationMode(.middle)
        .contentTransition(.numericText())
        .animation(reduceMotion ? nil : .snappy, value: call)
    }
}
