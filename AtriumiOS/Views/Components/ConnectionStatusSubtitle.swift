import SwiftUI

/// Notes a lost connection under the title instead of covering the screen, so
/// what's already loaded stays usable. It says it's reconnecting as soon as the
/// connection drops, such as on returning from the background, and that the
/// host can't be reached if that keeps failing. Once connected it shows
/// `subtitle` again, or nothing.
struct ConnectionStatusSubtitle: ViewModifier {
    @Environment(CompanionClient.self) private var client
    var subtitle = ""
    var showsStatus = true
    @State private var notice: String?

    func body(content: Content) -> some View {
        content
            .navigationSubtitle((showsStatus ? notice : nil) ?? subtitle)
            .task(id: client.isReconnecting) {
                guard client.isReconnecting else {
                    notice = nil
                    return
                }
                notice = "Reconnecting…"
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                notice = "Can’t reach your host · Pull to retry"
            }
    }
}
