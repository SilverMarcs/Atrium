import AppKit

extension PreviewCapture.Source {
    func perform(_ action: LivePreviewInput) async throws {
        try Task.checkCancellation()
        switch self {
        case .browser(let browser):
            try await browser.performPreviewInput(action)
        case .simulator(let simulator):
            try await simulator.performPreviewInput(action)
        }
    }
}

private extension AgentBrowser {
    func performPreviewInput(_ action: LivePreviewInput) async throws {
        func cssPoint(_ point: PreviewPoint) throws -> CGPoint {
            try point.inSize(cssSize)
        }

        switch action {
        case .tap(let point):
            await click(at: try cssPoint(point), count: 1, modifiers: [])
        case .swipe(let from, let to):
            let start = try cssPoint(from)
            let end = try cssPoint(to)
            await scroll(at: start, deltaX: start.x - end.x, deltaY: start.y - end.y)
        case .text(let text):
            try checkPreviewText(text)
            await type(text)
        case .key(let key):
            try await press(key.rawValue, modifiers: [])
        case .openPage(let address):
            try checkPreviewText(address)
            guard let url = Self.url(fromTyped: address), let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else {
                throw PreviewError("Enter a web address or a search.")
            }
            startNavigation(.open(url))
        case .back:
            if canGoBack { startNavigation(.back) }
        case .forward:
            if canGoForward { startNavigation(.forward) }
        case .reload:
            startNavigation(.reload)
        case .home:
            throw PreviewError("Home is available in the simulator.")
        }
    }
}

private extension SimulatorSession {
    func performPreviewInput(_ action: LivePreviewInput) async throws {
        guard isBooted else { throw PreviewError("This simulator isn’t running.") }

        switch action {
        case .tap(let point):
            try await tap(at: point.inSize(turnedPointSize))
        case .swipe(let from, let to):
            try await drag(from: from.inSize(turnedPointSize), to: to.inSize(turnedPointSize), duration: 0.22)
        case .text(let text):
            try checkPreviewText(text)
            try await type(text, submit: false)
        case .key(let key):
            if let stroke = SimulatorKeys.usage(named: key.rawValue) {
                await SimulatorKeys.press(stroke.usage, on: input)
            }
        case .home:
            input.press(.home)
            await input.flush()
        case .openPage, .back, .forward, .reload:
            throw PreviewError("Page controls are available in the browser.")
        }
    }
}

private extension PreviewPoint {
    func inSize(_ size: CGSize) throws -> CGPoint {
        guard isValid, size.width > 0, size.height > 0 else { throw PreviewError("The preview point is outside the screen.") }
        return CGPoint(x: x * size.width, y: y * size.height)
    }
}

private func checkPreviewText(_ text: String) throws {
    guard text.utf8.count <= LivePreviewInput.maxTextBytes else { throw PreviewError("Send up to 4 KB of text at a time.") }
}
