import SwiftUI

/// The glass circle after the resting composer bar's field: Send, tinted,
/// enabled for content or dictation, or Stop while the agent works. Hidden,
/// its glass melts into the expanded panel.
struct ComposerBarActionButton: View {
    enum Action { case send, stop }

    let action: Action
    /// Sending saves an edited message.
    let isEditing: Bool
    let isEnabled: Bool
    let isHidden: Bool
    let perform: () -> Void

    var body: some View {
        Button(role: action == .stop ? .destructive : nil, action: perform) {
            Label(title, systemImage: symbol)
                .labelStyle(.iconOnly)
                .font(.title2)
                .bold(action == .send)
                .foregroundStyle(action == .send ? .white : .red)
                .opacity(isHidden ? 0 : isEnabled ? 1 : 0.5)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(.circle)
        .glassEffect(glass, in: .circle)
        .scaleEffect(isHidden ? 0.8 : 1)
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .allowsHitTesting(!isHidden)
        .accessibilityHidden(isHidden)
    }

    private var title: String {
        switch action {
        case .send: isEditing ? "Save and Continue" : "Send"
        case .stop: "Stop"
        }
    }

    private var symbol: String {
        switch action {
        case .send: isEditing ? "checkmark" : "arrow.up"
        case .stop: "stop.fill"
        }
    }

    private var glass: Glass {
        if isHidden { return .identity }
        return action == .send ? .regular.tint(.accentColor).interactive() : .regular.interactive()
    }
}
