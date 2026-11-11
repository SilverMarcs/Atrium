import SwiftUI

/// The inspector lists' disclosure arrow, drawn to match an outline's own:
/// a little smaller, heavier and brighter than a plain secondary chevron.
struct DisclosureChevron: View {
    let isExpanded: Bool

    var body: some View {
        Image(systemName: "chevron.right")
            .font(.subheadline)
            // The system's disclosure arrow is heavier than regular text weight.
            .fontWeight(.semibold)
            .imageScale(.small)
            .foregroundStyle(.primary.opacity(0.65))
            .rotationEffect(.degrees(isExpanded ? 90 : 0))
            .accessibilityHidden(true)
    }
}
