import AtriumProtocol
import SwiftUI

/// Opens a page an agent showed in a sheet: a card for screens too narrow to
/// show it inline, or a compact row for a version a later turn revised.
struct ChatPageButton: View {
    let page: TranscriptPage
    var isEarlierVersion = false
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            if isEarlierVersion {
                HStack(spacing: 6) {
                    Image(systemName: "clock.arrow.circlepath")
                        .imageScale(.small)
                    Text("\(page.title) · Earlier version")
                        .font(.caption)
                        .lineLimit(1)
                    Image(systemName: "chevron.right")
                        .imageScale(.small)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.background.secondary, in: .capsule)
                .contentShape(.capsule)
            } else {
                HStack(spacing: 12) {
                    Image(systemName: "rectangle.on.rectangle")
                        .font(.title3)
                        .foregroundStyle(.tint)
                        .frame(width: 36, height: 36)
                        .background(.tint.quinary, in: .rect(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(page.title)
                            .font(.subheadline.bold())
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Text("View page")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Image(systemName: "chevron.right")
                        .imageScale(.small)
                        .foregroundStyle(.secondary)
                }
                .padding(10)
                .background(.background.secondary, in: .rect(cornerRadius: 14))
                .contentShape(.rect(cornerRadius: 14))
            }
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens the page the agent made.")
        .sheet(isPresented: $isPresented) {
            ChatPageSheet(page: page)
        }
    }
}
