import SwiftUI

/// A round button over a page. Its symbol sits in a fixed square, so every
/// control is the same size whatever symbol it shows.
struct ChatPageControl: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label {
                Text(title)
            } icon: {
                Image(systemName: systemImage)
                    .frame(width: 16, height: 16)
                    .contentTransition(.symbolEffect(.replace))
            }
            .labelStyle(.iconOnly)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .controlSize(.small)
        .help(title)
    }
}
