import AppKit

/// The tools that drive a chat's own browser, for the agents this Mac runs:
/// each chat gets one tab, which the user watches in the inspector beside it.
/// Agents read pages as text outlines with element refs and act with real
/// clicks and keys; pictures come only when they ask.
@MainActor
struct BrowserTools {
    typealias Tool = ToolServer.Tool
    typealias ToolCall = ToolServer.ToolCall
    typealias Failure = ToolServer.Failure
    typealias Reply = ToolServer.Reply

    let browsers: AgentBrowsers

    private static let devices = AgentBrowser.Device.allCases.map(\.rawValue)

    var tools: [Tool] {
        [
            Tool(
                name: "browser_open",
                description: """
                    Opens a page in your chat's own browser (WebKit, like Safari), which the user watches, and can use, \
                    beside the chat. Use it to build and test sites and to browse, rather than computer use or another \
                    browser: http://localhost:<port> for a dev server, or a file path. Sign-ins stay across chats. Waits \
                    for the load, then returns the page's snapshot, as browser_snapshot does.
                    """,
                properties: [
                    "url": ToolSchema.string("The address, such as https://example.com, localhost:3000 or /path/to/index.html."),
                    "device": ["type": "string", "enum": Self.devices, "description": "Lay the page out as this device, as browser_viewport does."],
                ],
                required: ["url"], audience: .localAgents, reply: open
            ),
            Tool(
                name: "browser_snapshot",
                description: """
                    Reads your chat's browser page as text: its URL, viewport, the console errors, failed requests and \
                    downloads since you last looked, then an outline with one element per line (role, name, state) and a \
                    ref such as e12 for each one you can act on. Refs last until the next snapshot or action. Work from \
                    this text; add a screenshot only when how the page looks matters, such as checking a design.
                    """,
                properties: [
                    "scope": ["type": "string", "enum": ["page", "viewport"], "description": "The whole page (default), or only what's on screen."],
                    "screenshot": ["type": "string", "enum": ["viewport", "page", "element"],
                                   "description": "Also return a PNG of what's on screen, the whole page, or the element `ref` names. It's saved too, for showing in your reply."],
                    "ref": ToolSchema.string("For an element screenshot: the element's ref."),
                ],
                audience: .localAgents, reply: snapshot
            ),
            Tool(
                name: "browser_act",
                description: """
                    Acts on your chat's browser page with real mouse and keyboard events, waits for what it sets off \
                    (loads, requests, the page settling), then returns the new snapshot of what's on screen. Target an \
                    element by `ref` from the latest snapshot or a CSS `selector`, or a point with x and y in CSS pixels \
                    of the visible page (for canvases). click (click_count 2 or 3), double_click, right_click; hover; \
                    type `text` into the element, or what has focus, with `clear` to replace its text and `submit` to \
                    press Enter after; press one `key` (Enter, Tab, Escape, Backspace, ArrowDown, a letter…) with \
                    `modifiers`, such as Meta+a; select `values` of a <select> by value or label; scroll by delta_y and \
                    delta_x at the element or the middle of the page, or with no delta scroll the element into view; \
                    drag the element onto `to_ref` or `to_selector`; upload absolute `files` through a file input or the \
                    button that opens one; back, forward, reload. Dialogs the action opens are accepted unless `dialog` \
                    is dismiss. Hover moves the pointer there and runs the page's hover events, but CSS :hover \
                    styles may not show; drag runs page events.
                    """,
                properties: [
                    "action": ["type": "string", "enum": ["click", "double_click", "right_click", "hover", "type", "press", "select", "scroll",
                                                          "drag", "upload", "back", "forward", "reload"]],
                    "ref": ToolSchema.string("The element's ref from the latest snapshot, such as e12."),
                    "selector": ToolSchema.string("A CSS selector for the element, instead of ref."),
                    "x": ToolSchema.number("A point to act at instead of an element: CSS pixels from the visible page's left."),
                    "y": ToolSchema.number("CSS pixels from the visible page's top."),
                    "to_ref": ToolSchema.string("For drag: the element to drop on."),
                    "to_selector": ToolSchema.string("For drag: a CSS selector for the element to drop on."),
                    "text": ToolSchema.string("For type: the text to enter."),
                    "clear": ToolSchema.boolean("For type: replace the field's text rather than add to it."),
                    "submit": ToolSchema.boolean("For type: press Enter after."),
                    "key": ToolSchema.string("For press: a key name, such as Enter, or one character."),
                    "modifiers": ["type": "array", "items": ["type": "string", "enum": ["Alt", "Control", "Meta", "Shift"]],
                                  "description": "For click and press: keys held down. Meta is Command."],
                    "values": ToolSchema.strings("For select: the options to select, by value or label."),
                    "files": ToolSchema.strings("For upload: absolute paths of the files to choose."),
                    "click_count": ToolSchema.integer("For click: 1 to 3 (default 1)."),
                    "delta_x": ToolSchema.number("For scroll: CSS pixels to the right."),
                    "delta_y": ToolSchema.number("For scroll: CSS pixels down."),
                    "dialog": ["type": "string", "enum": ["accept", "dismiss"], "description": "How to answer an alert, confirm or prompt the action opens (default accept)."],
                    "prompt_text": ToolSchema.string("For a prompt the action opens: the text to answer with."),
                    "snapshot": ["type": "string", "enum": ["viewport", "page", "none"],
                                 "description": "What to return after: what's on screen (default), the whole page, or only the URL and news."],
                ],
                required: ["action"], audience: .localAgents, reply: act
            ),
            Tool(
                name: "browser_wait_for",
                description: """
                    Waits until your chat's browser page shows `text`, no longer shows `text_gone`, has a visible element \
                    for `selector` or none for `selector_gone`, and its URL contains `url_contains`: all you give. Then \
                    returns the snapshot of what's on screen. Use it after starting something slow, rather than sleeping.
                    """,
                properties: [
                    "text": ToolSchema.string("Text the page should show."),
                    "text_gone": ToolSchema.string("Text the page should no longer show."),
                    "selector": ToolSchema.string("A CSS selector for an element that should be visible."),
                    "selector_gone": ToolSchema.string("A CSS selector for an element that should be gone or hidden."),
                    "url_contains": ToolSchema.string("Part of the URL to wait for."),
                    "timeout_seconds": ToolSchema.number("How long to wait (default 10, at most 60)."),
                ],
                audience: .localAgents, reply: waitFor
            ),
            Tool(
                name: "browser_logs",
                description: """
                    Reads your chat's browser console (every level) or its network requests (the page's own loads, \
                    fetch and XHR calls with status and timing, failed loads, downloads), new since you last read them \
                    here unless `all`. Pass a request's id to see it in full with its request and response bodies.
                    """,
                properties: [
                    "kind": ["type": "string", "enum": ["console", "network"], "description": "Which log (default console)."],
                    "all": ToolSchema.boolean("Everything kept (the latest 300), not only what's new."),
                    "problems_only": ToolSchema.boolean("Only errors and warnings, or failed requests."),
                    "request": ToolSchema.string("A request's id, from the network log, to read in full."),
                ],
                audience: .localAgents, reply: logs
            ),
            Tool(
                name: "browser_evaluate",
                description: """
                    Runs JavaScript in your chat's browser page as the body of an async function; `return` a JSON value \
                    to read it, up to 64 KB. Use it to read what the snapshot leaves out or check the page's state, such \
                    as storage or computed styles; use browser_act for input a person would make.
                    """,
                properties: ["script": ToolSchema.string("The function body, such as `return localStorage.getItem('token')`.")],
                required: ["script"], audience: .localAgents, reply: evaluate
            ),
            Tool(
                name: "browser_viewport",
                description: """
                    Sets the size your chat's browser lays pages out at, to test a layout: a `device` (phones and \
                    tablets also get that device's user agent, and the page reloads), or `width` and `height` in CSS \
                    pixels. reset fills wherever the page shows again. The user sees it scaled to fit.
                    """,
                properties: [
                    "device": ["type": "string", "enum": Self.devices],
                    "landscape": ToolSchema.boolean("Turn the device sideways."),
                    "width": ToolSchema.number("CSS pixels wide, instead of a device."),
                    "height": ToolSchema.number("CSS pixels tall."),
                    "reset": ToolSchema.boolean("Fill the view again."),
                ],
                audience: .localAgents, reply: setViewport
            ),
        ]
    }

    // MARK: - Tools

    private func open(_ call: ToolCall) async throws -> Reply {
        let caller = try caller(of: call)
        guard let url = AgentBrowser.url(from: try call.required("url")) else { throw Failure("Give an http, https or file address.") }
        let browser = browsers.browserOpening(for: caller)
        browsers.noteAgentUse(by: caller)
        if let device = try device(call) { await browser.setViewport(device.viewport()) }
        try await acting(browser, call) {
            try await browser.open(url)
            await browser.settle()
        }
        return Reply(text: try await browser.snapshot(viewportOnly: false))
    }

    private func snapshot(_ call: ToolCall) async throws -> Reply {
        let browser = try browser(for: call)
        let text = try await browser.snapshot(viewportOnly: call.string("scope") == "viewport")
        guard let area = call.string("screenshot") else { return Reply(text: text) }
        let png: Data
        switch area {
        case "page": png = try await browser.screenshot(.page)
        case "element":
            guard let ref = call.string("ref") else { throw Failure("An element screenshot needs ref.") }
            png = try await browser.screenshot(.element(ref))
        default: png = try await browser.screenshot(.viewport)
        }
        let file = try save(png)
        return Reply(text: text + "\n\nScreenshot saved to \(file.path(percentEncoded: false))", png: png)
    }

    private func act(_ call: ToolCall) async throws -> Reply {
        let browser = try browser(for: call)
        let action = try call.required("action")
        let note: String? = try await acting(browser, call) {
            try await perform(action, call, on: browser)
        }
        let after: String
        switch call.string("snapshot") {
        case "page": after = try await browser.snapshot(viewportOnly: false)
        case "none": after = browser.status()
        default: after = try await browser.snapshot(viewportOnly: true)
        }
        return Reply(text: [note, after].compactMap(\.self).joined(separator: "\n\n"))
    }

    private func waitFor(_ call: ToolCall) async throws -> Reply {
        let browser = try browser(for: call)
        let condition = AgentBrowser.Condition(
            text: call.string("text"), textGone: call.string("text_gone"), selector: call.string("selector"),
            selectorGone: call.string("selector_gone"), urlContains: call.string("url_contains"))
        let seconds = min(max(call.double("timeout_seconds") ?? 10, 0.5), 60)
        try await browser.wait(for: condition, seconds: seconds)
        return Reply(text: try await browser.snapshot(viewportOnly: true))
    }

    private func logs(_ call: ToolCall) async throws -> Reply {
        let browser = try browser(for: call)
        if let id = call.string("request") {
            guard let text = browser.request(id) else { throw Failure("No request \(id) is kept; read the network log for ids.") }
            return Reply(text: text)
        }
        return Reply(text: browser.logs(network: call.string("kind") == "network", all: call.bool("all") ?? false,
                                        problemsOnly: call.bool("problems_only") ?? false))
    }

    private func evaluate(_ call: ToolCall) async throws -> Reply {
        let browser = try browser(for: call)
        let script = try call.required("script")
        return Reply(text: try await acting(browser, call) { try await browser.evaluate(script) })
    }

    private func setViewport(_ call: ToolCall) async throws -> Reply {
        let browser = try browser(for: call)
        if call.bool("reset") == true {
            await browser.setViewport(nil)
        } else if let device = try device(call) {
            await browser.setViewport(device.viewport(landscape: call.bool("landscape") ?? false))
        } else if let width = call.double("width"), let height = call.double("height"), (100...4000).contains(width), (100...4000).contains(height) {
            await browser.setViewport(AgentBrowser.Viewport(width: width, height: height))
        } else {
            throw Failure("Give a device, width and height (100 to 4000), or reset.")
        }
        return Reply(text: browser.status())
    }

    // MARK: - Acting

    /// Performs one action; returns a note when it did something other than asked.
    private func perform(_ action: String, _ call: ToolCall, on browser: AgentBrowser) async throws -> String? {
        let ref = call.string("ref"), selector = call.string("selector")
        let hasElement = ref != nil || selector != nil
        let modifiers = Self.modifiers(call.strings("modifiers"))
        var note: String?

        /// The element's middle once it's in view, or the point given.
        func target() async throws -> CGPoint {
            if hasElement {
                let box = try await browser.locate(ref: ref, selector: selector)
                guard box.width > 0, box.height > 0 else {
                    throw Failure("\(ref ?? selector ?? "That element") isn't drawn on the page (hidden or empty); pick another, or use browser_evaluate.")
                }
                if let covered = box.covered { note = "\(covered) covers \(ref ?? selector ?? "it"), so the click landed on that, as a person's would." }
                return box.center
            }
            if let x = call.double("x"), let y = call.double("y") { return CGPoint(x: x, y: y) }
            throw Failure("\(action) needs ref, selector, or x and y.")
        }

        switch action {
        case "click", "double_click":
            let count = action == "double_click" ? 2 : min(max(call.int("click_count") ?? 1, 1), 3)
            await browser.click(at: try await target(), count: count, modifiers: modifiers)
        case "right_click":
            guard hasElement else { throw Failure("right_click needs ref or selector.") }
            _ = try await browser.locate(ref: ref, selector: selector)
            try await browser.help("contextmenu", ref: ref, selector: selector)
        case "hover":
            await browser.move(to: try await target())
            if hasElement { try await browser.help("hover", ref: ref, selector: selector) }
        case "type":
            let text = call.arguments["text"] as? String ?? ""
            if hasElement {
                let box = try await browser.locate(ref: ref, selector: selector)
                if box.width > 0, box.height > 0 { await browser.click(at: box.center, count: 1, modifiers: []) }
                try await browser.help(call.bool("clear") == true ? "selectText" : "caretToEnd", ref: ref, selector: selector)
            } else if call.bool("clear") == true {
                try await browser.press("a", modifiers: [.command])
            }
            await browser.type(text)
            if call.bool("submit") == true { try await browser.press("Enter", modifiers: []) }
        case "press":
            guard let key = call.arguments["key"] as? String, !key.isEmpty else { throw Failure("press needs a key.") }
            if hasElement { await browser.click(at: try await target(), count: 1, modifiers: []) }
            try await browser.press(key, modifiers: modifiers)
        case "select":
            guard hasElement else { throw Failure("select needs ref or selector.") }
            _ = try await browser.locate(ref: ref, selector: selector)
            try await browser.help("select", ref: ref, selector: selector, arguments: ["values": call.strings("values")])
        case "scroll":
            let dx = call.double("delta_x") ?? 0, dy = call.double("delta_y") ?? 0
            if hasElement, dx == 0, dy == 0 {
                _ = try await browser.locate(ref: ref, selector: selector)
            } else {
                let size = browser.cssSize
                let point = hasElement || call.double("x") != nil ? try await target() : CGPoint(x: size.width / 2, y: size.height / 2)
                await browser.scroll(at: point, deltaX: dx, deltaY: dy)
            }
        case "drag":
            guard hasElement, call.string("to_ref") != nil || call.string("to_selector") != nil else {
                throw Failure("drag needs the element (ref or selector) and where to drop it (to_ref or to_selector).")
            }
            _ = try await browser.locate(ref: ref, selector: selector)
            try await browser.help("drag", ref: ref, selector: selector,
                                   arguments: ["toRef": call.string("to_ref") ?? NSNull(), "toSelector": call.string("to_selector") ?? NSNull()])
        case "upload":
            let files = call.strings("files").map { URL(filePath: $0) }
            guard !files.isEmpty else { throw Failure("upload needs files.") }
            for file in files where !FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) {
                throw Failure("There's no file at \(file.path(percentEncoded: false)).")
            }
            guard hasElement else { throw Failure("upload needs the file input, or the button that opens it, by ref or selector.") }
            browser.pendingUploads = files
            defer { browser.pendingUploads = nil }
            if try await browser.help("openFileChooser", ref: ref, selector: selector) != "opened" {
                await browser.click(at: try await target(), count: 1, modifiers: [])
            }
            try? await Task.sleep(for: .milliseconds(300))
            // The file chooser takes the files when it opens.
            if browser.pendingUploads != nil { throw Failure("No file chooser opened; target the file input or the button that opens it.") }
        case "back": try await browser.goBack()
        case "forward": try await browser.goForward()
        case "reload": try await browser.reload()
        default: throw Failure("Unknown action \(action).")
        }
        await browser.settle()
        return note
    }

    /// Runs an agent's work with the dialogs it opens answered as it asked.
    private func acting<T>(_ browser: AgentBrowser, _ call: ToolCall, _ work: () async throws -> T) async throws -> T {
        browser.agentDialogs = (call.string("dialog") != "dismiss", call.arguments["prompt_text"] as? String)
        defer { browser.agentDialogs = nil }
        return try await work()
    }

    private static func modifiers(_ names: [String]) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        for name in names {
            switch name.lowercased() {
            case "alt", "option": flags.insert(.option)
            case "control", "ctrl": flags.insert(.control)
            case "meta", "command", "cmd": flags.insert(.command)
            case "shift": flags.insert(.shift)
            default: break
            }
        }
        return flags
    }

    // MARK: - Helpers

    private func device(_ call: ToolCall) throws -> AgentBrowser.Device? {
        guard let name = call.string("device") else { return nil }
        guard let device = AgentBrowser.Device(rawValue: name) else { throw Failure("Unknown device \(name).") }
        return device
    }

    /// Saves a screenshot where the agent can show it in its reply, beside
    /// the agent's downloads in the system's temporary folder.
    private func save(_ png: Data) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "Atrium Browser Screenshots", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "\(UUID().uuidString.prefix(8)).png")
        try png.write(to: file)
        return file
    }

    private func caller(of call: ToolCall) throws -> String {
        guard let caller = call.caller else { throw Failure("Atrium couldn't tell which of its chats this call comes from.") }
        return caller
    }

    private func browser(for call: ToolCall) throws -> AgentBrowser {
        let caller = try caller(of: call)
        guard let browser = browsers.browser(for: caller) else {
            throw Failure("Your chat has no page open; open one with browser_open.")
        }
        browsers.noteAgentUse(by: caller)
        return browser
    }
}
