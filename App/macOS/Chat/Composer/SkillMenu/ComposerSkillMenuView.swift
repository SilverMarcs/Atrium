import AtriumProtocol
import SwiftUI

/// The Mac skill menu's items, or why there are none. `ComposerSkillMenu`
/// hosts it in a panel with Liquid Glass behind it.
///
/// Rows have a fixed height, so the menu's size follows from the skills
/// alone: replacing the hosting view's root sizes the panel at once, before
/// it moves. Past `visibleRows` the list scrolls, following the highlight.
struct ComposerSkillMenuView: View {
    let skills: [AgentSkill]
    let status: String?
    let state: ComposerSkillMenuState
    let select: (AgentSkill) -> Void

    private typealias Metrics = ComposerSkillMenuMetrics

    var body: some View {
        let rows = status == nil ? min(skills.count, Metrics.visibleRows) : 1
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    if let status {
                        Text(status)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, Metrics.itemPadding)
                            .frame(maxWidth: .infinity, minHeight: Metrics.rowHeight, alignment: .leading)
                    } else {
                        ForEach(skills) { skill in
                            ComposerSkillMenuRow(
                                skill: skill,
                                isHighlighted: skill.id == state.highlightedID,
                                highlight: { state.highlightedID = skill.id },
                                select: { select(skill) }
                            )
                            .id(skill.id)
                        }
                    }
                }
                .padding(Metrics.inset)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(width: Metrics.width, height: CGFloat(rows) * Metrics.rowHeight + Metrics.inset * 2)
            .onChange(of: state.highlightedID) { _, id in
                // Only the keyboard moves it out of view; the pointer
                // highlights rows already showing.
                if let id { proxy.scrollTo(id) }
            }
        }
    }
}

/// One skill in the Mac skill menu, drawn as a menu item: its name over its
/// description, the highlight an accent-coloured rounded rect with the text
/// in white.
private struct ComposerSkillMenuRow: View {
    let skill: AgentSkill
    let isHighlighted: Bool
    let highlight: () -> Void
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 1) {
                Text(skill.name)
                    .foregroundStyle(isHighlighted ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                if !skill.description.isEmpty {
                    Text(skill.description)
                        .font(.caption)
                        .foregroundStyle(isHighlighted ? AnyShapeStyle(.white.secondary) : AnyShapeStyle(.secondary))
                }
            }
            .lineLimit(1)
            .padding(.horizontal, ComposerSkillMenuMetrics.itemPadding)
            .frame(maxWidth: .infinity, minHeight: ComposerSkillMenuMetrics.rowHeight,
                   maxHeight: ComposerSkillMenuMetrics.rowHeight, alignment: .leading)
            .background {
                if isHighlighted {
                    RoundedRectangle(cornerRadius: ComposerSkillMenuMetrics.itemCornerRadius)
                        .fill(.tint)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        // A menu highlights what the pointer passes over.
        .onContinuousHover { phase in
            if case .active = phase, !isHighlighted { highlight() }
        }
        .accessibilityAddTraits(isHighlighted ? .isSelected : [])
    }
}

/// The skill menu's geometry, matched to a macOS menu.
enum ComposerSkillMenuMetrics {
    /// Between the menu's edge and its items.
    static let inset: CGFloat = 5
    /// Between an item's highlight and its content.
    static let itemPadding: CGFloat = 7
    static let itemCornerRadius: CGFloat = 6
    static let cornerRadius: CGFloat = 11
    static let width: CGFloat = 320
    /// A name over a line of description.
    static let rowHeight: CGFloat = 36
    /// The rows shown before the list scrolls.
    static let visibleRows = 8
    /// Between the menu and the line it's anchored to, enough to clear the
    /// composer's padding above its first line.
    static let lineSpacing: CGFloat = 16

    /// From the menu's leading edge to an item's text.
    static var textOffset: CGFloat { inset + itemPadding }
}
