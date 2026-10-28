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
                    Label {
                        Text(composer.messageEdit == nil ? "Send" : "Save and Continue")
                    } icon: {
                        // Measure every state with the Send glyph so the circle
                        // keeps its size while the edit's rewind is in flight.
                        Image(systemName: "arrow.up")
                            .hidden()
                            .overlay {
                                if isSubmittingEdit {
                                    ProgressView()
                                        .controlSize(.small)
                                        .tint(.white)
                                } else {
                                    Image(systemName: composer.messageEdit == nil ? "arrow.up" : "checkmark")
                                }
                            }
                    }
                    .labelStyle(.iconOnly)
                    .font(.title3)
                    .bold()
                }
                .opacity(isSendDisabled && !isSubmittingEdit ? 0.35 : 0.85)
                .allowsHitTesting(!isSendDisabled)
            }
        }
        .buttonStyle(.glassProminent)
        .buttonBorderShape(.circle)
        .offset(y: -2)
    }

    private var isSubmittingEdit: Bool { composer.messageEdit?.isSubmitting == true }

    private var isSendDisabled: Bool {
        item == nil || composer.isSubmittingDictation || (composer.messageEdit != nil && composer.messageEdit?.canSubmit != true) || (!composer.hasContent && !composer.dictation.isActive)
    }
}
