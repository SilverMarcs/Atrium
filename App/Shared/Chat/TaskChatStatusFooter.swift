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
        Text("\(Text(call.name).bold())\(argument.map { " \($0)" } ?? "")")
            .font(.body)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .contentTransition(.numericText())
            .animation(reduceMotion ? nil : .snappy, value: call)
    }

    /// The argument, cut so the whole line stays within `maxLength`.
    private var argument: String? {
        guard let argument = call.argument else { return nil }
        guard let maxLength else { return argument }
        let room = maxLength - call.name.count - 1
        guard argument.count > room else { return argument }
        return room > 1 ? String(argument.prefix(room - 1)) + "…" : nil
    }
}
