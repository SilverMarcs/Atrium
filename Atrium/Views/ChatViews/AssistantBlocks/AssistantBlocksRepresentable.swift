import ACP
import SwiftUI

struct AssistantBlocksRepresentable: NSViewRepresentable {
    let blocks: [MessageBlock]
    let fontSize: CGFloat
    var cachedHeight: CGFloat = 0
    var calculatedHeight: Binding<CGFloat>? = nil
    var onOpenFile: ((String) -> Void)? = nil

    @MainActor
    final class Coordinator {
        private var renderTask: Task<Void, Never>?
        private var lastBlocksHash: Int?
        private var lastThemeName: String?

        deinit { renderTask?.cancel() }

        func update(
            nsView: AssistantBlocksContainerView,
            blocks: [MessageBlock],
            fontSize: CGFloat,
            themeName: String
        ) {
            let hash = Self.hash(blocks: blocks, fontSize: fontSize, themeName: themeName)
            guard hash != lastBlocksHash || themeName != lastThemeName else { return }
            lastBlocksHash = hash
            lastThemeName = themeName

            renderTask?.cancel()
            let renderer = AssistantBlocksRenderer(fontSize: fontSize, themeName: themeName)
            let capturedBlocks = blocks
            renderTask = Task { [weak nsView] in
                let document = await Task.detached(priority: .utility) {
                    await renderer.render(blocks: capturedBlocks)
                }.value
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let nsView else { return }
                    nsView.apply(document: document)
                }
            }
        }

        private static func hash(blocks: [MessageBlock], fontSize: CGFloat, themeName: String) -> Int {
            var hasher = Hasher()
            hasher.combine(fontSize)
            hasher.combine(themeName)
            for block in blocks {
                hasher.combine(block.id)
                hasher.combine(block.type)
                hasher.combine(block.text)
                hasher.combine(block.toolCallId)
                hasher.combine(block.toolTitle)
                hasher.combine(block.toolKind)
                hasher.combine(block.toolStatus)
                hasher.combine(block.diffPath)
                hasher.combine(block.diffOldText)
                hasher.combine(block.diffNewText)
            }
            return hasher.finalize()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> AssistantBlocksContainerView {
        AssistantBlocksContainerView()
    }

    func updateNSView(_ nsView: AssistantBlocksContainerView, context: Context) {
        nsView.onThemeChange = { [weak nsView] themeName in
            guard let nsView else { return }
            context.coordinator.update(
                nsView: nsView,
                blocks: blocks,
                fontSize: fontSize,
                themeName: themeName
            )
        }
        nsView.onHeightChange = { newHeight in
            guard let calculatedHeight, calculatedHeight.wrappedValue != newHeight else { return }
            calculatedHeight.wrappedValue = newHeight
        }
        nsView.onOpenFile = onOpenFile
        context.coordinator.update(
            nsView: nsView,
            blocks: blocks,
            fontSize: fontSize,
            themeName: nsView.activeThemeName
        )
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: AssistantBlocksContainerView,
        context: Context
    ) -> CGSize? {
        guard let width = proposal.width else { return nil }
        let measured = nsView.measuredSize(for: width)
        // If NSView hasn't rendered yet but we have a cached height, use it
        // to prevent List from guessing and causing scroll jumps
        if measured.height <= 0 && cachedHeight > 0 {
            return CGSize(width: width, height: cachedHeight)
        }
        return measured
    }
}
