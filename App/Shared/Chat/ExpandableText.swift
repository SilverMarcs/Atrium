//
//  ExpandableText.swift
//  Atrium
//
//  Adapted from LynkChat
//

import SwiftUI

/// A long prompt shown by its opening characters. The Mac expands it in place;
/// iPhone and iPad open the whole message in a sheet, so the timeline never
/// grows by screens of text.
struct ExpandableText: View {
    let text: String
    let maxCharacters: Int
    /// Skills to tint where the text names them.
    let skillNames: Set<String>
    let skillTint: Color

    @State private var isExpanded = false
    @State private var showingFullText = false
    private let needsExpansion: Bool

    init(text: String, maxCharacters: Int = 400, skillNames: Set<String>, skillTint: Color) {
        self.text = text
        self.maxCharacters = maxCharacters
        self.skillNames = skillNames
        self.skillTint = skillTint
        self.needsExpansion = text.count > maxCharacters
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            Text(SkillMentions.attributed(displayedText, names: skillNames, tint: skillTint))
                .textSelection(.enabled)
                .lineSpacing(2)

            if needsExpansion {
                #if os(macOS)
                Button(isExpanded ? "Show Less" : "Show More") {
                    isExpanded.toggle()
                }
                .buttonBorderShape(.capsule)
                #else
                Button("Show More") {
                    showingFullText = true
                }
                .buttonBorderShape(.capsule)
                .sheet(isPresented: $showingFullText) {
                    FullMessageSheet(text: text)
                }
                #endif
            }
        }
    }

    private var displayedText: String {
        guard needsExpansion && !isExpanded else {
            return text
        }
        return String(text.prefix(maxCharacters))
    }
}
