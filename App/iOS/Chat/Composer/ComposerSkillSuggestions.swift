import SwiftUI

/// The slash suggestions on iPhone and iPad: a glass panel resting just
/// above the composer, as wide as its expanded panel, over the timeline.
/// Rows scroll once there are more than fit in `maximumHeight`. The Mac
/// shows them in `ComposerSkillMenu` instead.
struct ComposerSkillSuggestions: View {
    let skills: [AgentSkill]
    /// Why there are no skills, shown in their place.
    let status: String?
    let select: (AgentSkill) -> Void

    /// The rows' own height, so the panel is only as tall as they are.
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                if let status {
                    Text(status)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, Self.textInset)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(skills) { skill in
                        Button {
                            select(skill)
                        } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(skill.name)
                                if !skill.description.isEmpty {
                                    Text(skill.description)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .lineLimit(1)
                            .padding(.horizontal, Self.textInset)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.vertical, 6)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: min(contentHeight, Self.maximumHeight))
        .clipShape(.rect(cornerRadius: ComposerBarLayout.cornerRadius))
        .glassEffect(.regular, in: .rect(cornerRadius: ComposerBarLayout.cornerRadius))
    }

    private static let maximumHeight: CGFloat = 240
    /// Lines the names up with the draft's text below.
    private static let textInset = ComposerEditor.horizontalInset
}
