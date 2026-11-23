import SwiftUI

/// Keep active-turn geometry stable while questions or approvals wait in a sheet.
/// Once the agent calls a tool, the latest call shows in place of the spinner.
struct TaskChatStatusFooter: View {
    let status: AgentThreadStatus
    var toolCall: TranscriptToolCall?

    var body: some View {
        switch status {
        case .processing, .waiting:
            // The spinner stays laid out under the line, so the footer keeps its height.
            ZStack(alignment: .leading) {
                ProgressView()
                    #if os(macOS)
                    .controlSize(.small)
                    #endif
                    .opacity(toolCall == nil ? 1 : 0)
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

/// A tool call's name and argument on one line, shimmering while it runs.
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
        .modifier(Shimmer())
    }
}

/// A bright band sweeping across the content, after SwiftUI-Shimmer
/// (github.com/markiv/SwiftUI-Shimmer).
private struct Shimmer: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isAtStart = true

    private static let band: CGFloat = 0.3
    private static let gradient = Gradient(colors: [.black.opacity(0.4), .black, .black.opacity(0.4)])

    func body(content: Content) -> some View {
        if !reduceMotion {
            content
                .mask {
                    LinearGradient(
                        gradient: Self.gradient,
                        startPoint: UnitPoint(x: isAtStart ? -Self.band : 1, y: 0.5),
                        endPoint: UnitPoint(x: isAtStart ? 0 : 1 + Self.band, y: 0.5)
                    )
                }
                .animation(.linear(duration: 1.5).delay(0.25).repeatForever(autoreverses: false), value: isAtStart)
                .onAppear { isAtStart = false }
                // A lazy stack can keep this state while the footer is off screen,
                // so the sweep starts over when it comes back.
                .onDisappear {
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { isAtStart = true }
                }
        } else {
            content
        }
    }
}
