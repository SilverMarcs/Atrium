import SwiftUI

struct DiffHunkHeaderView: View {
    let hunk: DiffHunk
    let reference: GitDiffReference
    let onReload: () async -> Void

    @State private var showDiscardAlert = false

    var body: some View {
        HStack(spacing: 8) {
            Text(hunk.header)
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()

            switch reference.stage {
            case .unstaged:
                Button("Discard", role: .destructive) {
                    showDiscardAlert = true
                }
                .controlSize(.small)

                Button("Stage") {
                    Task { await applyHunk(reverse: false, cached: true) }
                }
                .controlSize(.small)
            case .staged:
                Button("Unstage") {
                    Task { await applyHunk(reverse: true, cached: true) }
                }
                .controlSize(.small)
            case .commit:
                EmptyView()
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.regularMaterial)
        .alert("Discard Changes", isPresented: $showDiscardAlert) {
            Button("Discard", role: .destructive) {
                Task { await applyHunk(reverse: true, cached: false) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Are you sure you want to discard this hunk? This cannot be undone.")
        }
    }

    private func applyHunk(reverse: Bool, cached: Bool) async {
        do {
            try await GitRepository.shared.applyPatch(
                hunk.patchText,
                reverse: reverse,
                cached: cached,
                at: reference.repositoryRootURL
            )
            await onReload()
        } catch {
            await DiffPopoverPresenter.showError("Apply failed: \(error.localizedDescription)")
        }
    }
}
