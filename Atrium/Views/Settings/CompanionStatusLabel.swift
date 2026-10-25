import SwiftUI

struct CompanionStatusLabel: View {
    let status: CompanionServer.Status

    var body: some View {
        switch status {
        case .stopped:
            Text("Off")
                .foregroundStyle(.secondary)
        case .starting:
            Text("Starting…")
                .foregroundStyle(.secondary)
        case .running(let description):
            Label(description, systemImage: "circle.fill")
                .foregroundStyle(.secondary)
                .labelStyle(CompanionStatusLabelStyle(color: .green))
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }
    }
}
