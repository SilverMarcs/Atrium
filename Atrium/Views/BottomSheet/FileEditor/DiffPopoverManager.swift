import AppKit
import SwiftUI

enum DiffPopoverPresenter {
    static func showDiffPopover(
        for hunk: GutterDiffHunk,
        at point: NSPoint,
        in textView: EditorTextView,
        repositoryRootURL: URL?,
        onReload: (() async -> Void)?
    ) {
        let gutterWidth = EditorTextViewConstants.gutterWidth
        let currentLines = textView.string.components(separatedBy: "\n")
        var popoverLines: [SharedDiffLine] = []

        if !hunk.oldContent.isEmpty {
            let oldLines = hunk.oldContent.components(separatedBy: "\n")
            for (i, line) in oldLines.enumerated() {
                popoverLines.append(
                    SharedDiffLine(
                        content: line,
                        kind: .removed,
                        oldLineNumber: hunk.oldStart + i,
                        newLineNumber: nil
                    )
                )
            }
        }

        if hunk.kind == .added || hunk.kind == .modified, hunk.newCount > 0 {
            let start = max(hunk.newStart - 1, 0)
            let end = min(start + hunk.newCount, currentLines.count)
            for i in start..<end {
                popoverLines.append(
                    SharedDiffLine(
                        content: currentLines[i],
                        kind: .added,
                        oldLineNumber: nil,
                        newLineNumber: i + 1
                    )
                )
            }
        }

        guard !popoverLines.isEmpty else { return }

        let wrapLines = UserDefaults.standard.object(forKey: "editorWrapLines") as? Bool ?? true
        let popoverWidth: CGFloat = 560
        let maxPopoverHeight: CGFloat = 250
        let headerHeight: CGFloat = 32
        let layout = SharedDiffTextLayout.popover(wrapsLines: wrapLines)

        let popoverTextView = SharedDiffTextView()
        popoverTextView.frame = NSRect(x: 0, y: 0, width: popoverWidth, height: 0)
        popoverTextView.configure(
            lines: popoverLines,
            fileExtension: textView.fileExtension,
            layout: layout,
            width: popoverWidth
        )

        let contentHeight: CGFloat
        if let layoutManager = popoverTextView.layoutManager, let textContainer = popoverTextView.textContainer {
            layoutManager.ensureLayout(for: textContainer)
            let usedRect = layoutManager.usedRect(for: textContainer)
            contentHeight = usedRect.height + layout.verticalPadding * 2
        } else {
            contentHeight = CGFloat(popoverLines.count) * 17 + layout.verticalPadding * 2
        }

        let scrollView = NSScrollView()
        scrollView.documentView = popoverTextView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        popoverTextView.frame = NSRect(x: 0, y: 0, width: popoverWidth, height: contentHeight)
        popoverTextView.isVerticallyResizable = false

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        let addedCount = popoverLines.filter { $0.kind == .added }.count
        let removedCount = popoverLines.filter { $0.kind == .removed }.count

        let headerView = NSHostingView(
            rootView: DiffPopoverHeaderView(
                addedCount: addedCount,
                removedCount: removedCount,
                stage: hunk.stage,
                onDiscard: repositoryRootURL.map { rootURL in
                    {
                        Task {
                            do {
                                try await GitRepository.shared.applyPatch(
                                    hunk.patchText,
                                    reverse: true,
                                    cached: false,
                                    at: rootURL
                                )
                                await onReload?()
                            } catch {
                                await DiffPopoverPresenter.showError("Discard failed: \(error.localizedDescription)")
                            }
                            await MainActor.run { popover.performClose(nil) }
                        }
                    }
                },
                onUnstage: repositoryRootURL.map { rootURL in
                    {
                        Task {
                            do {
                                try await GitRepository.shared.applyPatch(
                                    hunk.patchText,
                                    reverse: true,
                                    cached: true,
                                    at: rootURL
                                )
                                await onReload?()
                            } catch {
                                await DiffPopoverPresenter.showError("Unstage failed: \(error.localizedDescription)")
                            }
                            await MainActor.run { popover.performClose(nil) }
                        }
                    }
                },
                onStage: repositoryRootURL.map { rootURL in
                    {
                        Task {
                            do {
                                try await GitRepository.shared.applyPatch(
                                    hunk.patchText,
                                    reverse: false,
                                    cached: true,
                                    at: rootURL
                                )
                                await onReload?()
                            } catch {
                                await DiffPopoverPresenter.showError("Stage failed: \(error.localizedDescription)")
                            }
                            await MainActor.run { popover.performClose(nil) }
                        }
                    }
                }
            )
        )
        headerView.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(headerView)
        container.addSubview(scrollView)

        NSLayoutConstraint.activate([
            headerView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            headerView.topAnchor.constraint(equalTo: container.topAnchor),
            headerView.heightAnchor.constraint(equalToConstant: headerHeight),

            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: headerView.bottomAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        let viewController = NSViewController()
        viewController.view = container
        viewController.preferredContentSize = NSSize(
            width: popoverWidth,
            height: min(contentHeight, maxPopoverHeight) + headerHeight
        )
        popover.contentViewController = viewController

        let anchorRect = NSRect(x: gutterWidth - 2, y: point.y - 4, width: 4, height: 8)
        popover.show(relativeTo: anchorRect, of: textView, preferredEdge: .maxX)
    }

    @MainActor
    static func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Git Apply Error"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
