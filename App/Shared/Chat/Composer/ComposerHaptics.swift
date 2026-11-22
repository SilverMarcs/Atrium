import AtriumClient
import AtriumProtocol
import SwiftUI

struct ComposerHaptics: ViewModifier {
    static let enabledKey = "chatHapticsEnabled"
    #if os(iOS)
    @AppStorage(Self.enabledKey) private var isEnabled = true
    #endif
    let composer: TaskComposer
    let item: HostTask?

    func body(content: Content) -> some View {
        content
            #if os(iOS)
            .sensoryFeedback(trigger: composer.feedback) { _, event in
                feedback(for: event)
            }
            .sensoryFeedback(.error, trigger: composer.dictation.error) { _, error in isEnabled && error != nil }
            .sensoryFeedback(.error, trigger: item?.host.actionError) { _, error in isEnabled && error != nil }
            #endif
    }

    #if os(iOS)
    private func feedback(for event: ComposerFeedback?) -> SensoryFeedback? {
        guard isEnabled else { return nil }
        return switch event?.kind {
        case .recordingStarted, .transcriptReady: .impact(weight: .light, intensity: 0.8)
        case .send: .impact(weight: .medium, intensity: 0.7)
        case .stop, .scratchpad: .impact(weight: .light, intensity: 0.7)
        case nil: nil
        }
    }
    #endif
}
