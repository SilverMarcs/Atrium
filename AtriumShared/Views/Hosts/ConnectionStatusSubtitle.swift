import AtriumClient
import SwiftUI

/// Notes lost connections under the title instead of covering the screen, so
/// what's already loaded stays usable. It says it's reconnecting as soon as a
/// connection drops, such as on returning from the background, and which host
/// can't be reached if that keeps failing. Otherwise it shows `subtitle`, or nothing.
struct ConnectionStatusSubtitle: ViewModifier {
    let hosts: [HostClient]
    var subtitle = ""
    var showsStatus = true
    @State private var notice: String?

    private var offline: [HostClient] { hosts.filter { !$0.isConnected } }

    /// iOS lists retry when pulled down; the Mac keeps reconnecting on its own.
    #if os(iOS)
    private static let retryHint = " · Pull to retry"
    #else
    private static let retryHint = ""
    #endif

    func body(content: Content) -> some View {
        content
            .navigationSubtitle((showsStatus ? notice : nil) ?? subtitle)
            .task(id: offline.map(\.id)) {
                guard !offline.isEmpty else {
                    notice = nil
                    return
                }
                notice = "Reconnecting…"
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                let unreachable = offline.count == 1 ? offline[0].name : "\(offline.count) hosts"
                notice = "Can’t reach \(unreachable)\(Self.retryHint)"
            }
    }
}
