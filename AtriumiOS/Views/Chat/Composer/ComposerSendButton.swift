import SwiftUI

/// The inline composer's Send button. While the agent works and there's no
/// draft to send, it stops the agent instead.
struct ComposerSendButton: View {
    @Environment(TaskComposer.self) private var composer
    let item: HostTask?
    let send: () -> Void

    var body: some View {
        Group {
            if let item, item.task.actions.contains(.interrupt), !composer.hasContent, !composer.dictation.isActive, !composer.isSubmittingDictation {
                Button(role: .destructive) {
                    item.host.interrupt(item.task.id)
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
        item == nil || composer.isSubmittingDictation || (!composer.hasContent && !composer.dictation.isActive)
    }
}
