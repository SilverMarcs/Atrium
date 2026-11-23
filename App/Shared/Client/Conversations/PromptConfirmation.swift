import Foundation

nonisolated struct PromptConfirmation: Sendable {
  let promptID: UUID
  let messageID: String
}
