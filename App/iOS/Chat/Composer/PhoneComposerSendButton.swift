import AtriumClient
import AtriumProtocol
import SwiftUI

/// Send, at the end of the expanded iPhone composer's button row. While the
/// agent works and there's nothing to send, it stops the agent instead.
///
/// A solid circle rather than glass: inside the composer's glass container,
/// glass this close would melt into the panel around it.
struct PhoneComposerSendButton: View {
    @Environment(TaskComposer.self) private var composer
    let item: HostTask?
    let send: () -> Void

    @ScaledMetric(relativeTo: .body) private var diameter = 34

    var body: some View {
        if let item, composer.offersStop(for: item.task.actions) {
            Button("Stop", systemImage: "stop.fill", role: .destructive) {
                item.host.interrupt(item.task.id)
            }
            .buttonStyle(PhoneComposerSendButtonStyle(diameter: diameter, fill: .red))
        } else {
            Button(composer.messageEdit == nil ? "Send" : "Save and Continue", systemImage: composer.messageEdit == nil ? "arrow.up" : "checkmark", action: send)
                .buttonStyle(PhoneComposerSendButtonStyle(diameter: diameter, fill: .accentColor, isBusy: isSubmittingEdit))
                .opacity(isSendDisabled && !isSubmittingEdit ? 0.35 : 1)
                .allowsHitTesting(!isSendDisabled)
        }
    }

    private var isSubmittingEdit: Bool { composer.messageEdit?.isSubmitting == true }

    private var isSendDisabled: Bool { item == nil || !composer.canSend }
}

private struct PhoneComposerSendButtonStyle: ButtonStyle {
    let diameter: CGFloat
    let fill: Color
    var isBusy = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(.iconOnly)
            .font(.body)
            .bold()
            .foregroundStyle(.white)
            .opacity(isBusy ? 0 : 1)
            .overlay {
                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                }
            }
            .frame(width: diameter, height: diameter)
            .background(fill, in: .circle)
            .contentShape(.circle)
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
