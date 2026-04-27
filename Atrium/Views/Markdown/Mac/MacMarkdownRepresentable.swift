import SwiftUI

struct MarkdownRenderRequest: Hashable, Sendable {
    let text: String
    let fontSize: CGFloat
    let themeName: String
}

@MainActor
private final class MarkdownRenderCacheStore {
    private final class Node {
        let key: MarkdownRenderRequest
        var value: MarkdownRenderedDocument
        var prev: Node?
        var next: Node?

        init(key: MarkdownRenderRequest, value: MarkdownRenderedDocument) {
            self.key = key
            self.value = value
        }
    }

    static let shared = MarkdownRenderCacheStore()

    private let cacheLimit = 120
    private var map: [MarkdownRenderRequest: Node] = [:]
    private var head: Node? // most recently used
    private var tail: Node? // least recently used

    func document(for request: MarkdownRenderRequest) -> MarkdownRenderedDocument? {
        guard let node = map[request] else { return nil }
        moveToHead(node)
        return node.value
    }

    func store(_ document: MarkdownRenderedDocument, for request: MarkdownRenderRequest) {
        if let node = map[request] {
            node.value = document
            moveToHead(node)
        } else {
            let node = Node(key: request, value: document)
            map[request] = node
            insertAtHead(node)

            if map.count > cacheLimit {
                if let evicted = tail {
                    removeNode(evicted)
                    map.removeValue(forKey: evicted.key)
                }
            }
        }
    }

    private func moveToHead(_ node: Node) {
        guard node !== head else { return }
        removeNode(node)
        insertAtHead(node)
    }

    private func insertAtHead(_ node: Node) {
        node.prev = nil
        node.next = head
        head?.prev = node
        head = node
        if tail == nil { tail = node }
    }

    private func removeNode(_ node: Node) {
        node.prev?.next = node.next
        node.next?.prev = node.prev
        if node === head { head = node.next }
        if node === tail { tail = node.prev }
        node.prev = nil
        node.next = nil
    }
}

actor MarkdownRenderScheduler {
    static let shared = MarkdownRenderScheduler()

    private var inFlightTasks: [MarkdownRenderRequest: Task<MarkdownRenderedDocument, Never>] = [:]

    func document(for request: MarkdownRenderRequest) async -> MarkdownRenderedDocument {
        if let existingTask = inFlightTasks[request] {
            return await existingTask.value
        }

        let renderTask = Task.detached(priority: .utility) {
            await MacMarkdownRenderer(fontSize: request.fontSize, themeName: request.themeName).render(request.text)
        }

        inFlightTasks[request] = renderTask
        let document = await renderTask.value
        inFlightTasks[request] = nil
        return document
    }
}

struct MacMarkdownRepresentable: NSViewRepresentable {
    let text: String
    let fontSize: CGFloat
    let isStreaming: Bool
    var calculatedHeight: Binding<CGFloat>?

    @MainActor
    final class Coordinator {
        private let streamingRenderDelay: Duration = .milliseconds(180)
        private var currentRequest: MarkdownRenderRequest?
        private var pendingRenderRequest: MarkdownRenderRequest?
        private var lastRenderedRequest: MarkdownRenderRequest?
        private var lastRenderedDocument: MarkdownRenderedDocument?
        private var streamingBuffer: NSMutableAttributedString?
        private var lastStreamedTextLength: Int = 0
        private var renderTask: Task<Void, Never>?

        deinit {
            renderTask?.cancel()
        }

        func update(
            nsView: MarkdownContainerView,
            text: String,
            fontSize: CGFloat,
            themeName: String,
            isStreaming: Bool
        ) {
            let request = MarkdownRenderRequest(text: text, fontSize: fontSize, themeName: themeName)

            if let cachedDocument = MarkdownRenderCacheStore.shared.document(for: request) {
                renderTask?.cancel()
                renderTask = nil
                pendingRenderRequest = nil
                applyRenderedDocument(cachedDocument, for: request, to: nsView)
                return
            }

            if isStreaming, let streamedDocument = streamedDocument(for: request) {
                currentRequest = request
                nsView.apply(document: streamedDocument, for: request, isStreamed: true)
            } else if lastRenderedDocument == nil {
                currentRequest = request
                nsView.showPlaceholder(text: text, fontSize: fontSize, for: request)
            } else {
                currentRequest = request
            }

            guard pendingRenderRequest != request || !isStreaming else {
                return
            }

            let renderDelay = isStreaming && shouldCoalesceStreamingRender(for: request)
                ? streamingRenderDelay
                : .zero
            pendingRenderRequest = request
            renderTask?.cancel()
            renderTask = Task { [weak nsView] in
                if renderDelay > .zero {
                    try? await Task.sleep(for: renderDelay)
                }

                guard !Task.isCancelled else { return }
                let document = await MarkdownRenderScheduler.shared.document(for: request)
                guard !Task.isCancelled else { return }

                await MainActor.run {
                    MarkdownRenderCacheStore.shared.store(document, for: request)

                    guard let nsView, self.currentRequest == request else { return }
                    self.pendingRenderRequest = nil
                    self.applyRenderedDocument(document, for: request, to: nsView)
                }
            }
        }

        private func streamedDocument(for request: MarkdownRenderRequest) -> MarkdownRenderedDocument? {
            guard let lastRenderedRequest,
                  let lastRenderedDocument,
                  lastRenderedRequest.fontSize == request.fontSize,
                  lastRenderedRequest.themeName == request.themeName,
                  request.text.hasPrefix(lastRenderedRequest.text),
                  request.text != lastRenderedRequest.text else {
                streamingBuffer = nil
                return nil
            }

            if streamingBuffer == nil {
                streamingBuffer = NSMutableAttributedString(attributedString: lastRenderedDocument.attributedString)
                lastStreamedTextLength = lastRenderedRequest.text.count
            }

            let newText = String(request.text.dropFirst(lastStreamedTextLength))
            if !newText.isEmpty {
                streamingBuffer!.append(MarkdownRenderedDocument.plainTextFragment(newText, fontSize: request.fontSize))
                lastStreamedTextLength = request.text.count
            }

            return MarkdownRenderedDocument(
                attributedString: NSAttributedString(attributedString: streamingBuffer!),
                codeBlocks: lastRenderedDocument.codeBlocks,
                quoteBlocks: lastRenderedDocument.quoteBlocks,
                tableBlocks: lastRenderedDocument.tableBlocks,
                hasThematicBreaks: lastRenderedDocument.hasThematicBreaks
            )
        }

        private func shouldCoalesceStreamingRender(for request: MarkdownRenderRequest) -> Bool {
            guard let lastRenderedRequest else { return false }
            return lastRenderedRequest.fontSize == request.fontSize &&
                lastRenderedRequest.themeName == request.themeName &&
                request.text.hasPrefix(lastRenderedRequest.text) &&
                request.text != lastRenderedRequest.text
        }

        private func applyRenderedDocument(
            _ document: MarkdownRenderedDocument,
            for request: MarkdownRenderRequest,
            to nsView: MarkdownContainerView
        ) {
            streamingBuffer = nil
            currentRequest = request
            lastRenderedRequest = request
            lastRenderedDocument = document
            nsView.apply(document: document, for: request)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> MarkdownContainerView {
        MarkdownContainerView()
    }

    func updateNSView(_ nsView: MarkdownContainerView, context: Context) {
        nsView.onThemeChange = { [weak nsView] themeName in
            guard let nsView else { return }
            context.coordinator.update(
                nsView: nsView,
                text: text,
                fontSize: fontSize,
                themeName: themeName,
                isStreaming: isStreaming
            )
        }
        nsView.onHeightChange = { newHeight in
            guard let calculatedHeight, calculatedHeight.wrappedValue != newHeight else { return }
            calculatedHeight.wrappedValue = newHeight
        }
        context.coordinator.update(
            nsView: nsView,
            text: text,
            fontSize: fontSize,
            themeName: nsView.activeThemeName,
            isStreaming: isStreaming
        )
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: MarkdownContainerView,
        context: Context
    ) -> CGSize? {
        guard let width = proposal.width else { return nil }
        return nsView.measuredSize(for: width)
    }
}
