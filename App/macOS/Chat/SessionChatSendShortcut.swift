import SwiftUI

struct SessionChatSendShortcut: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.keyboardShortcut(.return, modifiers: .command)
        } else {
            content
        }
    }
}
