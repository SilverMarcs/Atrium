import SwiftUI

/// One Send/Stop control travels above the composer's glass between its
/// resting circle and the smaller filled circle inside the expanded panel.
struct ComposerBarActionButton: View {
    enum Action { case send, stop }

    let action: Action
    let isExpanded: Bool
    let isEditing: Bool
    let isEnabled: Bool
    let isBusy: Bool
    let perform: () -> Void

    #if os(macOS)
    @ScaledMetric(relativeTo: .body) private var expandedDiameter = 26
    #else
    @ScaledMetric(relativeTo: .body) private var expandedDiameter = 34
    #endif

    var body: some View {
        Button(role: action == .stop ? .destructive : nil) {
            guard isEnabled && !isBusy else { return }
            perform()
        } label: {
            Circle()
                .fill(action == .stop ? .red : .accentColor)
                .opacity(fillOpacity)
                .frame(width: isExpanded ? expandedDiameter : ComposerBarLayout.rowHeight,
                       height: isExpanded ? expandedDiameter : ComposerBarLayout.rowHeight)
                .frame(width: ComposerBarLayout.rowHeight, height: ComposerBarLayout.rowHeight)
                .overlay {
                    // The symbol stays centered in the same cell and keeps the
                    // same font while only the circle changes size.
                    Label(title, systemImage: symbol)
                        .labelStyle(.iconOnly)
                        .font(symbolFont)
                        .bold(action == .send)
                        .foregroundStyle(action == .stop && !isExpanded ? .red : .white)
                        .opacity(isBusy ? 0 : isDimmed ? 0.45 : 1)
                }
                .overlay {
                    if isBusy {
                        ProgressView()
                            .controlSize(isExpanded ? .small : .regular)
                            .tint(.white)
                            // AppKit's spinner follows its appearance, ignoring tint.
                            .environment(\.colorScheme, .dark)
                    }
                }
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        #if os(macOS)
        .disabled(!isEnabled || isBusy)
        #else
        .allowsHitTesting(isEnabled && !isBusy)
        #endif
        .accessibilityLabel(isBusy ? "Sending" : title)
        .accessibilityValue(!isEnabled && !isBusy ? "Unavailable" : "")
        .help(isBusy ? "Sending" : title)
        #if os(macOS)
        .keyboardShortcut(action == .stop ? nil : KeyboardShortcut(.return, modifiers: .command))
        #endif
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

    private var isDimmed: Bool { !isEnabled && !isBusy }

    private var symbolFont: Font {
        #if os(macOS)
        .body
        #else
        .title3
        #endif
    }

    private var fillOpacity: Double {
        if isExpanded { return isDimmed ? 0.3 : 1 }
        return action == .stop ? 0.1 : isDimmed ? 0.12 : 0.18
    }

}

/// Only the resting material participates in the container's glass morph.
/// The button and its symbol are separate, overlaid above this material.
struct ComposerBarActionGlass: View {
    let action: ComposerBarActionButton.Action
    let isExpanded: Bool
    let isEnabled: Bool
    let isBusy: Bool

    var body: some View {
        Color.clear
            .frame(width: ComposerBarLayout.rowHeight, height: ComposerBarLayout.rowHeight)
            .glassEffect(glass, in: .circle)
            .accessibilityHidden(true)
    }

    private var glass: Glass {
        if isExpanded { return .identity }
        if action == .send {
            return .regular.tint(.accentColor.opacity(!isEnabled && !isBusy ? 0.3 : 1))
                .interactive(isEnabled && !isBusy)
        }
        return .regular.interactive()
    }
}
