import SwiftUI

struct DiffPopoverHeaderView: View {
    let addedCount: Int
    let removedCount: Int
    let stage: GutterHunkStage
    var onDiscard: (() -> Void)?
    var onUnstage: (() -> Void)?
    var onStage: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            switch stage {
            case .unstaged:
                if let onStage {
                    Button("Stage", action: onStage)
                        .controlSize(.small)
                }
                if let onDiscard {
                    Button("Discard", role: .confirm, action: onDiscard)
                        .controlSize(.small)
                }
            case .staged:
                if let onUnstage {
                    Button("Unstage", action: onUnstage)
                        .controlSize(.small)
                }
            }

            Spacer()

            HStack(spacing: 4) {
                if addedCount > 0 {
                    Text("+\(addedCount)")
                        .foregroundStyle(.green)
                }
                if removedCount > 0 {
                    Text("-\(removedCount)")
                        .foregroundStyle(.red)
                }
            }
            .font(.caption.monospacedDigit())
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 4)
    }
}
