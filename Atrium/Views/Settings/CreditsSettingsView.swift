import SwiftUI

struct CreditsSettingsView: View {
    var body: some View {
        Form {
            Section("Open Source Attributions") {
                CreditRow(
                    name: "SwiftTerm",
                    url: "https://github.com/migueldeicaza/SwiftTerm"
                )

                CreditRow(
                    name: "Highlightr",
                    url: "https://github.com/raspu/Highlightr"
                )
            }
        }
        .formStyle(.grouped)
    }
}

private struct CreditRow: View {
    let name: String
    let url: String

    var body: some View {
        Link(destination: URL(string: url)!) {
            HStack(spacing: 10) {
                Label {
                    Text(name)
                    Text(url)
                } icon: {
                    EmptyView()
                }

                Spacer()

                Image(systemName: "arrow.up.forward")
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    CreditsSettingsView()
        .frame(width: 480, height: 400)
}
