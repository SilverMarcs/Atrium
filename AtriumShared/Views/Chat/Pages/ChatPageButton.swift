import AtriumProtocol
import SwiftUI

/// Opens a page an agent showed in a sheet, for screens too narrow to show it inline.
struct ChatPageButton: View {
    let page: TranscriptPage
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
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
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .background(.background.secondary, in: .rect(cornerRadius: 14))
            .contentShape(.rect(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens the page the agent made.")
        .sheet(isPresented: $isPresented) {
            ChatPageSheet(page: page)
        }
    }
}
