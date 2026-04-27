//
//  ExpandableText.swift
//  Atrium
//
//  Adapted from LynkChat
//

import SwiftUI

struct ExpandableText: View {
    let text: String
    let maxCharacters: Int

    @State private var isExpanded = false
    private let needsExpansion: Bool

    init(text: String, maxCharacters: Int = 400) {
        self.text = text
        self.maxCharacters = maxCharacters
        self.needsExpansion = text.count > maxCharacters
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            Text(displayedText)
                .textSelection(.enabled)
                .lineSpacing(2)

            if needsExpansion {
                Button {
                    isExpanded.toggle()
                } label: {
                    Text(isExpanded ? "Show Less" : "Show More")
                }
                .buttonBorderShape(.capsule)
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
