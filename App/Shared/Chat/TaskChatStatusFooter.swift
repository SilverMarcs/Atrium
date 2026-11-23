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

/// A tool call's name and argument on one line. In a wide chat it stops at
/// `maxLength` characters with the name, so a long command doesn't span the
/// chat; on iPhone it fills the line.
private struct ToolCallLine: View {
    let call: TranscriptToolCall
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    private var maxLength: Int? {
        #if os(iOS)
        sizeClass == .compact ? nil : 75
        #else
        75
        #endif
    }

    var body: some View {
        Group {
            if let argument {
                Text("\(call.name) \(Text(argument).foregroundStyle(.secondary))")
            } else {
                Text(call.name)
            }
        }
        .font(.callout)
        .lineLimit(1)
        .truncationMode(.tail)
        .contentTransition(.numericText())
        .animation(reduceMotion ? nil : .snappy, value: call)
    }

    private var argument: String? {
        guard let argument = call.argument, let maxLength else { return call.argument }
        let room = max(maxLength - call.name.count - 1, 1)
        return argument.count > room ? String(argument.prefix(room - 1)) + "…" : argument
    }
}
