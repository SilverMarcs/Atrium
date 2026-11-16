import AtriumProtocol
import SwiftUI

/// The slash suggestions in the editor's native popover, shared by Mac and iOS.
struct ComposerSkillSuggestions: View {
    let matches: [AgentSkill]
    let hasSkills: Bool
    let isLoading: Bool
    let failed: Bool
    let select: (AgentSkill) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isLoading {
                ProgressView("Loading Skills")
                    .padding()
            } else if matches.isEmpty {
                Text(failed ? "Skills Unavailable" : hasSkills ? "No Matching Skills" : "No Skills Available")
                    .foregroundStyle(.secondary)
                    .padding()
            } else {
                ForEach(matches.prefix(5)) { skill in
                    Button {
                        select(skill)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(skill.name)
                                if !skill.description.isEmpty {
                                    Text(skill.description)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 4)
                        .frame(minHeight: 44)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(minWidth: 280, idealWidth: 320, maxWidth: 360, alignment: .leading)
        .padding(.vertical, 4)
    }
}
