import SwiftUI

/// A small colored status dot ahead of the label's title.
struct StatusLabelStyle: LabelStyle {
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.icon
                .imageScale(.small)
                .foregroundStyle(color)
            configuration.title
        }
    }
}
