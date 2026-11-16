import AtriumClient
import AtriumProtocol
import SwiftUI

/// Flies a just-sent prompt's bubble in from the composer: each platform's
/// `PromptFlights`.
@MainActor
protocol PromptSendAnimating: AnyObject {
    /// Where the composer's field is, read at submission before clearing the
    /// draft can shrink it.
    var sourceFrame: (() -> CGRect?)? { get }
    /// Called just before the prompt joins the timeline, which can lay out its
    /// row and scroll for it before `begin`. That can be a while after the
    /// send was pressed: once dictation still recording has been transcribed,
    /// or once an edited prompt's turn has been removed.
    func willSend()
    /// Flies the prompt's bubble in. One without images is held at the top
    /// of the timeline, which is where it heads at once, before the timeline
    /// has laid out its row.
    func begin(_ promptID: PendingPrompt.ID, text: String, hasImages: Bool, from frame: CGRect?)
}

extension PromptSendAnimating {
    func willSend() {}
}
