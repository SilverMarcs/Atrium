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
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(session.title)
                        .font(.callout)
                        .lineLimit(1)
                    ProgressView()
                        .controlSize(.mini)
                        .frame(width: 14, height: 14)
                }
                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 5)
    }

    private var subtitle: String? {
        let trimmed = session.command.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed != session.title {
            return trimmed
        }
        return session.taskTitle.isEmpty ? nil : session.taskTitle
    }
}
