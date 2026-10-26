import SwiftUI

/// The inline composer's Send button. While the agent works and there's no
/// draft to send, it stops the agent instead.
struct ComposerSendButton: View {
    @Environment(CompanionClient.self) private var client
    @Environment(TaskComposer.self) private var composer
    let task: WireTask?
    let send: () -> Void

    var body: some View {
        Group {
            if let task, task.actions.contains(.interrupt), !composer.hasContent, !composer.dictation.isActive, !composer.isSubmittingDictation {
                Button(role: .destructive) {
                    client.send(.interrupt(taskID: task.id))
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                        .labelStyle(.iconOnly)
                        .font(.title3)
                }
                .tint(.red)
                .opacity(0.85)
            } else {
                Button(action: send) {
                    Label("Send", systemImage: "arrow.up")
                        .labelStyle(.iconOnly)
                        .font(.title3)
                        .bold()
                }
                .opacity(isSendDisabled ? 0.35 : 0.85)
                .allowsHitTesting(!isSendDisabled)
            }
        }
        .buttonStyle(.glassProminent)
        .buttonBorderShape(.circle)
        .offset(y: -2)
    }

    private var isSendDisabled: Bool {
        task == nil || composer.isSubmittingDictation || (!composer.hasContent && !composer.dictation.isActive)
    }
}
