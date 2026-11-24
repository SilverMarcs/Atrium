import AppKit
import ImageIO
import UniformTypeIdentifiers
import WebKit

/// What an agent does with its chat's browser: reading the page, acting on
/// it with real clicks and keys, waiting for it, and taking pictures of it.
extension AgentBrowser {
    private static let maximumOutline = 20_000

    // MARK: - Reading

    /// The page's state, then its outline: the whole page, or only what's on screen.
    func snapshot(viewportOnly: Bool) async throws -> String {
        let result: [String: Any]?
        do {
            result = try await webView.callAsyncJavaScript(
                BrowserScripts.snapshot, arguments: ["maxLength": Self.maximumOutline, "viewportOnly": viewportOnly],
                in: nil, contentWorld: Self.world) as? [String: Any]
        } catch {
            throw ToolServer.Failure("Couldn't read the page: \(Self.message(of: error))")
        }
        let outline = result?["outline"] as? String ?? ""
        var text = status() + news()
        text += "\n\n" + (outline.isEmpty ? "(Nothing on the page.)" : outline)
        if result?["truncated"] as? Bool == true { text += "\n(Cut off here; use browser_evaluate to read the rest.)" }
        let above = (result?["above"] as? NSNumber)?.intValue ?? 0, below = (result?["below"] as? NSNumber)?.intValue ?? 0
        if viewportOnly, above + below > 0 {
            text += "\n(Off screen: \(above) controls above, \(below) below. Scroll, or take a full snapshot.)"
        }
        return text
    }

    /// The address and title, the size pages lay out at, and what's open or loading.
    func status() -> String {
        var lines = ["URL: \(webView.url?.absoluteString ?? "about:blank")"]
        if let title = webView.title, !title.isEmpty { lines.append("Title: \(title)") }
        let size = cssSize
        lines.append("Viewport: \(Int(size.width))×\(Int(size.height))" + (viewport?.device.map { " (\($0.title))" } ?? ""))
        if webView.isLoading { lines.append("Still loading.") }
        for popup in openPopups { lines.append("A popup window is open for the user: \(popup)") }
        return lines.joined(separator: "\n")
    }

    /// The errors, warnings, failed requests and downloads since the agent last looked.
    private func news() -> String {
        let since = seenInSnapshot
        let problems = console.filter { $0.sequence > since && ["error", "warning", "dialog", "popup"].contains($0.level) }
        let failures = network.filter { $0.sequence > since && ($0.failed || $0.kind == "download") }
        seenInSnapshot = max(console.last?.sequence ?? 0, network.last?.sequence ?? 0, seenInSnapshot)
        guard !problems.isEmpty || !failures.isEmpty else { return "" }
        var lines = ["", "Since you last looked:"]
        for entry in problems.suffix(10) { lines.append("console \(entry.level): \(entry.text.prefix(500))") }
        for entry in failures.suffix(10) { lines.append(Self.line(entry)) }
        if problems.count > 10 || failures.count > 10 { lines.append("(More in browser_logs.)") }
        return lines.joined(separator: "\n")
    }

    static func line(_ entry: NetworkEntry) -> String {
        if let saved = entry.savedTo { return "downloaded \(entry.url) to \(saved)" }
        var line = "\(entry.method) \(entry.url) → "
        line += entry.error.map { "failed (\($0))" } ?? "\(entry.status ?? 0)"
        if let duration = entry.duration { line += " in \(duration) ms" }
        return line + " [\(entry.kind) \(entry.id)]"
    }

    /// The console, or the requests, since the agent last read them here or all that are kept.
    func logs(network showNetwork: Bool, all: Bool, problemsOnly: Bool) -> String {
        let since = all ? 0 : seenInLogs
        seenInLogs = max(console.last?.sequence ?? 0, network.last?.sequence ?? 0, seenInLogs)
        if showNetwork {
            let entries = network.filter { $0.sequence > since && (!problemsOnly || $0.failed) }
            return entries.isEmpty ? "No requests\(all ? "" : " since you last looked")." : entries.map(Self.line).joined(separator: "\n")
        }
        let entries = console.filter { $0.sequence > since && (!problemsOnly || ["error", "warning"].contains($0.level)) }
        return entries.isEmpty ? "Nothing logged\(all ? "" : " since you last looked")." : entries.map { "\($0.level): \($0.text)" }.joined(separator: "\n")
    }

    /// One request in full, with the bodies the page sent and got back.
    func request(_ id: String) -> String? {
        guard let entry = network.last(where: { $0.id == id }) else { return nil }
        var text = Self.line(entry)
        if !entry.type.isEmpty { text += "\nContent-Type: \(entry.type)" }
        if let body = entry.requestBody { text += "\n\nRequest body:\n\(body)" }
        if let body = entry.responseBody { text += "\n\nResponse body:\n\(body)" }
        return text
    }

    // MARK: - Pictures

    enum ScreenshotArea {
        case viewport
        case page
        case element(String)
    }

    /// A PNG of the visible page, the whole page, or one element, at one
    /// pixel per CSS pixel and at most 4000 pixels long.
    func screenshot(_ area: ScreenshotArea) async throws -> Data {
        if webView.window == nil { park() }
        let zoom = webView.pageZoom
        let configuration = WKSnapshotConfiguration()
        var restoreScroll: (Double, Double)?
        switch area {
        case .viewport:
            break
        case .page:
            let metrics = try await webView.callAsyncJavaScript(
                "const s = [scrollX, scrollY]; scrollTo(0, 0); return [s[0], s[1], document.documentElement.scrollWidth, document.documentElement.scrollHeight];",
                in: nil, contentWorld: Self.world) as? [NSNumber]
            guard let metrics, metrics.count == 4 else { break }
            restoreScroll = (metrics[0].doubleValue, metrics[1].doubleValue)
            configuration.rect = CGRect(x: 0, y: 0, width: webView.bounds.width, height: min(metrics[3].doubleValue * zoom, 30_000))
        case .element(let ref):
            let box = try await locate(ref: ref, selector: nil)
            configuration.rect = CGRect(x: box.x * zoom, y: box.y * zoom, width: max(box.width * zoom, 1), height: max(box.height * zoom, 1))
        }
        configuration.afterScreenUpdates = true
        let image = try await webView.takeSnapshot(configuration: configuration)
        if let restoreScroll {
            _ = try? await webView.callAsyncJavaScript("scrollTo(x, y)", arguments: ["x": restoreScroll.0, "y": restoreScroll.1], in: nil, contentWorld: Self.world)
        }
        let pixels = max(image.size.width, image.size.height) / zoom
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(pixels, 4000),
        ] as CFDictionary
        guard let tiff = image.tiffRepresentation, let source = CGImageSourceCreateWithData(tiff as CFData, nil),
              let picture = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { throw ToolServer.Failure("Couldn't take a screenshot.") }
        let png = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil) else {
            throw ToolServer.Failure("Couldn't take a screenshot.")
        }
        CGImageDestinationAddImage(destination, picture, nil)
        guard CGImageDestinationFinalize(destination) else { throw ToolServer.Failure("Couldn't take a screenshot.") }
        return png as Data
    }

    // MARK: - Finding elements

    struct Box {
        let x, y, width, height: Double
        let covered: String?
        let tag: String
        let type: String
        let editable: Bool

        var center: CGPoint { CGPoint(x: x + width / 2, y: y + height / 2) }
    }

    /// Scrolls the element into view and says where it is, in CSS pixels of the visible page.
    func locate(ref: String?, selector: String?) async throws -> Box {
        let value: Any?
        do {
            value = try await webView.callAsyncJavaScript(
                BrowserScripts.locate, arguments: ["ref": ref ?? NSNull(), "selector": selector ?? NSNull()], in: nil, contentWorld: Self.world)
        } catch {
            throw ToolServer.Failure(Self.message(of: error))
        }
        guard let box = value as? [String: Any] else { throw ToolServer.Failure("Couldn't find that element.") }
        let number = { (key: String) in (box[key] as? NSNumber)?.doubleValue ?? 0 }
        return Box(x: number("x"), y: number("y"), width: number("width"), height: number("height"), covered: box["covered"] as? String,
                   tag: box["tag"] as? String ?? "", type: box["type"] as? String ?? "", editable: box["editable"] as? Bool ?? false)
    }

    /// Runs one of the page-event helpers in Atrium's world.
    @discardableResult
    func help(_ action: String, ref: String?, selector: String?, arguments: [String: Any] = [:]) async throws -> String? {
        var all: [String: Any] = ["action": action, "ref": ref ?? NSNull(), "selector": selector ?? NSNull(), "values": [String](),
                                  "toRef": NSNull(), "toSelector": NSNull()]
        all.merge(arguments) { $1 }
        do {
            return try await webView.callAsyncJavaScript(BrowserScripts.helper, arguments: all, in: nil, contentWorld: Self.world) as? String
        } catch {
            throw ToolServer.Failure(Self.message(of: error))
        }
    }

    /// Runs the agent's own script in the page, returning its value as JSON.
    func evaluate(_ script: String) async throws -> String {
        let value: Any?
        do {
            value = try await webView.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page)
        } catch {
            throw ToolServer.Failure(Self.message(of: error))
        }
        await settle()
        guard let value, !(value is NSNull) else { return "null" }
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes]) {
            let text = String(decoding: data, as: UTF8.self)
            return text.count > 64_000 ? String(text.prefix(64_000)) + "… (cut off)" : text
        }
        return String(describing: value)
    }

    /// A script error's own message, rather than WebKit's wrapper around it.
    static func message(of error: any Error) -> String {
        let info = (error as NSError).userInfo
        return info["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription
    }

    // MARK: - Waiting

    /// Waits for what an action set off: a page load, the requests it made,
    /// and the page to stop changing, up to a few seconds.
    func settle() async {
        try? await Task.sleep(for: .milliseconds(100))
        let deadline = ContinuousClock.now + .seconds(3)
        let loadDeadline = ContinuousClock.now + Self.loadTimeout
        while ContinuousClock.now < loadDeadline, webView.isLoading {
            try? await Task.sleep(for: .milliseconds(50))
        }
        while ContinuousClock.now < deadline {
            let quiet = (try? await webView.callAsyncJavaScript(BrowserScripts.quietFor, in: nil, contentWorld: Self.world) as? NSNumber)?.doubleValue ?? 1000
            if inflightCount == 0, quiet >= 250 { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    struct Condition {
        var text: String?
        var textGone: String?
        var selector: String?
        var selectorGone: String?
        var urlContains: String?
    }

    /// Waits until the page meets every condition, or throws once the time is up.
    func wait(for condition: Condition, seconds: Double) async throws {
        let deadline = ContinuousClock.now + .milliseconds(Int(seconds * 1000))
        let arguments: [String: Any] = [
            "text": condition.text ?? NSNull(), "textGone": condition.textGone ?? NSNull(),
            "selector": condition.selector ?? NSNull(), "selectorGone": condition.selectorGone ?? NSNull(),
        ]
        while true {
            let urlMatches = condition.urlContains.map { webView.url?.absoluteString.contains($0) == true } ?? true
            if urlMatches, !webView.isLoading,
               (try? await webView.callAsyncJavaScript(BrowserScripts.check, arguments: arguments, in: nil, contentWorld: Self.world) as? Bool) == true {
                return
            }
            guard ContinuousClock.now < deadline else { throw ToolServer.Failure("Timed out after \(Int(seconds)) s waiting.\n\n" + status()) }
            try? await Task.sleep(for: .milliseconds(150))
        }
    }

    // MARK: - Real input

    /// A view point for a point in CSS pixels of the visible page.
    private func viewPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x * webView.pageZoom, y: point.y * webView.pageZoom)
    }

    /// Runs real input against the page. When the user was typing elsewhere
    /// in the same window, such as in the chat's composer, the keys go back
    /// there after; otherwise the page keeps focus, as it would for a person.
    func withRealInput<T>(focus: Bool = false, _ work: () async throws -> T) async rethrows -> T {
        if webView.window == nil { park() }
        let window = webView.window
        let typing = window !== parking ? window?.firstResponder as? NSText : nil
        if focus { window?.makeFirstResponder(webView) }
        defer {
            if let typing, !typing.isDescendant(of: webView) { window?.makeFirstResponder(typing) }
        }
        return try await work()
    }

    private func mouse(_ type: NSEvent.EventType, at point: CGPoint, clicks: Int = 1, modifiers: NSEvent.ModifierFlags = []) -> NSEvent? {
        guard let window = webView.window else { return nil }
        return NSEvent.mouseEvent(
            with: type, location: webView.convert(viewPoint(point), to: nil), modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0,
            clickCount: clicks, pressure: type == .leftMouseUp || type == .mouseMoved ? 0 : 1)
    }

    /// A real click, or several for a double or triple click, at a point in CSS pixels.
    func click(at point: CGPoint, count: Int, modifiers: NSEvent.ModifierFlags) async {
        await withRealInput {
            if let move = mouse(.mouseMoved, at: point, modifiers: modifiers) { webView.mouseMoved(with: move) }
            for n in 1...count {
                if let down = mouse(.leftMouseDown, at: point, clicks: n, modifiers: modifiers) { webView.mouseDown(with: down) }
                if let up = mouse(.leftMouseUp, at: point, clicks: n, modifiers: modifiers) { webView.mouseUp(with: up) }
            }
        }
    }

    /// Moves the pointer there, with real events.
    func move(to point: CGPoint) async {
        await withRealInput {
            if let move = mouse(.mouseMoved, at: point) { webView.mouseMoved(with: move) }
        }
    }

    /// Scrolls with a real wheel at a point in CSS pixels, positive deltas scrolling down and right.
    func scroll(at point: CGPoint, deltaX: Double, deltaY: Double) async {
        await withRealInput {
            guard let window = webView.window,
                  let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                      wheel1: Int32(-deltaY.rounded()), wheel2: Int32(-deltaX.rounded()), wheel3: 0) else { return }
            event.location = window.convertPoint(toScreen: webView.convert(viewPoint(point), to: nil))
            if let wheel = NSEvent(cgEvent: event) { webView.scrollWheel(with: wheel) }
        }
    }

    /// Types text with real key presses into whatever has focus.
    func type(_ text: String) async {
        await withRealInput(focus: true) {
            for character in text {
                if character == "\n" {
                    sendKey("Enter", modifiers: [])
                } else if let key = Keys.code(for: character) {
                    sendKey(String(character), code: key.code, modifiers: key.shift ? [.shift] : [])
                } else {
                    webView.insertText(String(character))
                }
            }
        }
        await waitForTyping(text)
    }

    /// WebKit takes queued keys one at a time, after the call that sent them
    /// returns; waits until the focused field ends with the text, or a moment
    /// when focus isn't on a field or the page changes what was typed.
    private func waitForTyping(_ text: String) async {
        let tail = String(text.split(separator: "\n").last ?? "").suffix(20)
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            let value = try? await webView.callAsyncJavaScript(
                "const e = document.activeElement; const v = e?.isContentEditable ? e.innerText : e?.value; return typeof v === 'string' ? v : null;",
                in: nil, contentWorld: Self.world) as? String
            guard let value, !tail.isEmpty else { break }
            if value.hasSuffix(tail) { return }
            try? await Task.sleep(for: .milliseconds(30))
        }
        try? await Task.sleep(for: .milliseconds(100))
    }

    /// Presses one key, such as Enter or a letter, with modifiers held, into whatever has focus.
    func press(_ key: String, modifiers: NSEvent.ModifierFlags) async throws {
        guard Keys.named[key] != nil || key.count == 1 else {
            throw ToolServer.Failure("Unknown key “\(key)”. Use one character or a name such as Enter, Tab, Escape, Backspace, Delete, ArrowUp, Home or PageDown.")
        }
        await withRealInput(focus: true) {
            sendKey(key, modifiers: modifiers)
        }
    }

    private func sendKey(_ key: String, code: UInt16? = nil, modifiers: NSEvent.ModifierFlags) {
        guard let window = webView.window else { return }
        let named = Keys.named[key]
        let character = named?.characters ?? key
        let code = code ?? named?.code ?? key.first.flatMap(Keys.code(for:))?.code ?? 0
        var flags = modifiers
        if key.count == 1, let first = key.first, first.isUppercase { flags.insert(.shift) }
        let typed = flags.contains(.shift) ? character : character.lowercased()
        func event(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                             windowNumber: window.windowNumber, context: nil, characters: typed,
                             charactersIgnoringModifiers: character.lowercased(), isARepeat: false, keyCode: code)
        }
        guard let down = event(.keyDown), let up = event(.keyUp) else { return }
        if flags.contains(.command), webView.performKeyEquivalent(with: down) {
            webView.keyUp(with: up)
            return
        }
        webView.keyDown(with: down)
        webView.keyUp(with: up)
    }
}

/// Mac key codes for the keys agents press, so pages see the right `code`.
private enum Keys {
    static let named: [String: (code: UInt16, characters: String)] = [
        "Enter": (36, "\r"), "Return": (36, "\r"), "Tab": (48, "\t"), "Escape": (53, "\u{1b}"), "Backspace": (51, "\u{7f}"),
        "Delete": (117, "\u{F728}"), "ArrowUp": (126, "\u{F700}"), "ArrowDown": (125, "\u{F701}"), "ArrowLeft": (123, "\u{F702}"),
        "ArrowRight": (124, "\u{F703}"), "Home": (115, "\u{F729}"), "End": (119, "\u{F72B}"), "PageUp": (116, "\u{F72C}"),
        "PageDown": (121, "\u{F72D}"), "Space": (49, " "), " ": (49, " "),
    ]

    private static let codes: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
        "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
        "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44,
        "n": 45, "m": 46, ".": 47, "`": 50, " ": 49,
    ]

    private static let shifted: [Character: Character] = [
        "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9", ")": "0", "_": "-", "+": "=",
        "{": "[", "}": "]", "|": "\\", ":": ";", "\"": "'", "<": ",", ">": ".", "?": "/", "~": "`",
    ]

    /// The key that types a character on a US keyboard, and whether it takes Shift.
    static func code(for character: Character) -> (code: UInt16, shift: Bool)? {
        if let code = codes[character] { return (code, false) }
        if character.isUppercase, let lower = character.lowercased().first, let code = codes[lower] { return (code, true) }
        if let base = shifted[character], let code = codes[base] { return (code, true) }
        return nil
    }
}
