import AppKit
import AtriumClient
import AtriumProtocol
import SwiftUI

/// Desktop message geometry from the original chat detail, using normalized transcripts.
///
/// Takes only values and compares them, so an update of the timeline (a send,
/// a status change, a streamed reply) updates just the rows whose message
/// changed. What a row does goes through `PromptActions` in the environment.
struct SessionChatMessageRow: View, Equatable {
  let message: TranscriptMessage
  let isStreaming: Bool
  /// A prompt in the transcript the agent can rewind or fork at; pending ones can't be yet.
  let isRewindable: Bool
  let pendingPrompt: PendingPrompt?
  @Environment(\.promptActions) private var actions

  nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.isStreaming == rhs.isStreaming && lhs.isRewindable == rhs.isRewindable
      && lhs.pendingPrompt == rhs.pendingPrompt && lhs.message == rhs.message
  }

  var body: some View {
    switch message.role {
    case .user:
      // A prompt sent from here keeps its pending row's ID once confirmed, so
      // the same bubble shows it throughout and only it can fly in.
      VStack(alignment: .trailing, spacing: 6) {
        UserMessageView(
          text: message.blocks.compactMap(\.text).joined(separator: "\n"),
          images: pendingPrompt?.images ?? message.images ?? [],
          isFromAgent: message.relay != nil,
          edit: isRewindable ? PromptAction(isEnabled: actions.isEditEnabled, perform: { [message] in actions.edit(message) }) : nil,
          fork: isRewindable ? PromptAction(isEnabled: actions.isForkEnabled, perform: { [message] in actions.fork(message) }) : nil,
          flightRowID: message.id.hasPrefix("pending-") ? message.id : nil)
        if let pendingPrompt, pendingPrompt.state == .failed {
          if let error = pendingPrompt.failureMessage { Text(error).font(.caption).foregroundStyle(.red) }
          Button("Retry", systemImage: "arrow.clockwise") { actions.retry(pendingPrompt.id) }
            .font(.caption)
            .buttonStyle(.borderless)
            .tint(.red)
        }
      }
    case .assistant:
      VStack(alignment: .leading, spacing: 8) {
        AssistantMessageView(blocks: message.blocks, isStreaming: isStreaming)
      }
      .contentShape(.rect)
      .transaction { $0.animation = nil }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.trailing, 30)
    }
  }
}

/// What the timeline's prompt bubbles do. Every value compares equal, so the
/// new one the timeline builds on each update doesn't update its rows; the
/// closures reach live state through the references they hold.
struct PromptActions: Equatable {
  var isEditEnabled: @MainActor () -> Bool = { false }
  var edit: @MainActor (TranscriptMessage) -> Void = { _ in }
  var isForkEnabled: @MainActor () -> Bool = { false }
  var fork: @MainActor (TranscriptMessage) -> Void = { _ in }
  var retry: @MainActor (UUID) -> Void = { _ in }

  nonisolated static func == (lhs: Self, rhs: Self) -> Bool { true }
}

extension EnvironmentValues {
  @Entry var promptActions = PromptActions()
}
