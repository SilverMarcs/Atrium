//
//  InfoPopover.swift
//  Atrium
//
//  Created by Zabir Raihan on 30/03/2026.
//

import SwiftUI

struct InfoPopover: View {
    let content: EditorPanelContent
    let fileURL: URL
    let directoryURL: URL

    var body: some View {
        Form {
            Section {
                LabeledContent("Kind") {
                    switch content {
                    case .file: Text("File Editor")
                    case .diff: Text("Diff View")
                    }
                }
                
                LabeledContent("Path") {
                    Text(fileURL.path(percentEncoded: false).replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                        .monospaced()
                }
                
                if case .diff(let ref) = content {
                    LabeledContent("Status") {
                        GitStatusBadge(kind: ref.kind, staged: ref.stage != .unstaged)
                    }
                    LabeledContent("Stage") {
                        Text(ref.stage.displayName)
                    }
                }
            } header: {
                Label {
                    Text(fileURL.lastPathComponent)
                        .fontWeight(.medium)
                } icon: {
                    Image(nsImage: fileURL.fileIcon)
                        .resizable()
                        .frame(width: 16, height: 16)
                }

            }
        }
        .formStyle(.grouped)
        .frame(width: 300)
    }
}
