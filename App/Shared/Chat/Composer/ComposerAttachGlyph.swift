import SwiftUI

/// The attachment button's +, which turns into the scratchpad's note for a
/// moment when a draft is put aside, to show where it went.
struct ComposerAttachGlyph: View {
    let composer: TaskComposer
    @State private var showsScratchpad = false

    var body: some View {
        Image(systemName: showsScratchpad ? "note.text" : "plus")
            .contentTransition(.symbolEffect(.replace))
            .symbolEffect(.bounce, value: showsScratchpad)
            .onChange(of: composer.feedback) { _, feedback in
                if feedback?.kind == .scratchpad { showsScratchpad = true }
            }
            .task(id: showsScratchpad) {
                guard showsScratchpad else { return }
                try? await Task.sleep(for: .seconds(1.2))
                showsScratchpad = false
            }
    }
}
