import SwiftUI

/// Notes a lost connection under the title instead of covering the screen, so
/// the tasks already loaded stay usable. Quick reconnects show nothing; a longer
/// one says it's reconnecting, and one that keeps failing says the Mac can't be reached.
struct ConnectionStatusSubtitle: ViewModifier {
    @Environment(CompanionClient.self) private var client
    @State private var notice: String?

    func body(content: Content) -> some View {
        content
            .navigationSubtitle(notice ?? "")
            .task(id: client.isReconnecting) {
                notice = nil
                guard client.isReconnecting else { return }
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                notice = "Reconnecting…"
                try? await Task.sleep(for: .seconds(27))
                guard !Task.isCancelled else { return }
                notice = "Can’t reach your Mac · Pull to retry"
            }
    }
}
