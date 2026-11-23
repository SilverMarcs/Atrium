import AtriumProtocol
import SwiftUI

/// One running agent background shell session in the Commands inspector list.
struct BackgroundSessionRow: View {
    let session: WireBackgroundSession

    var body: some View {
        HStack(spacing: 6) {
            ProviderIcon(provider: session.provider)
                .font(.callout)
                .frame(width: 18)
            Text(session.chatTitle)
                .font(.callout)
                .lineLimit(1)
            ProgressView()
                .controlSize(.mini)
                .frame(width: 14, height: 14)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 5)
        .help(session.command)
    }
}
