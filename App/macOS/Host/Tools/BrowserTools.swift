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
                    Opens a page in your chat's browser, which the user sees beside the chat, and returns its snapshot. \
                    Use the browser_* tools for web work and browsing, not computer use or another browser, unless the user \
                    names one.
                    """,
                properties: [
                    "url": ToolSchema.string("Such as https://example.com, localhost:3000 or a file path."),
                    "device": ToolSchema.choice(Self.devices),
                ],
                required: ["url"], audience: .localAgents, alwaysLoads: true, reply: open
            ),
            Tool(
                name: "browser_snapshot",
                description: """
                    Reads the page as a text outline: one element per line with a ref, such as e12, for each you can act \
                    on, after the console errors, failed requests and downloads since you last looked. Refs last until \
                    the next snapshot or action.
                    """,
                properties: [
                    "scope": ToolSchema.choice(["page", "viewport"], "Default page."),
                    "screenshot": ToolSchema.choice(["viewport", "page", "element"],
                                                    "Also return a PNG, saved to a file too. Only when how it looks matters."),
                    "ref": ToolSchema.string("For an element screenshot."),
                ],
                audience: .localAgents, reply: snapshot
            ),
            Tool(
                name: "browser_act",
                description: """
                    Acts on the page with real mouse and keyboard events, waits for it to settle, and returns a snapshot. \
                    Target an element by ref or selector, or a point by x and y. scroll with no delta scrolls the element \
                    into view. hover runs the page's events but may not show CSS :hover. `steps` runs several actions, \
                    all using refs from the snapshot before, and stops at the first that fails.
                    """,
                properties: [
                    "action": ToolSchema.choice(["click", "double_click", "right_click", "hover", "type", "press", "select", "scroll",
                                                 "drag", "upload", "back", "forward", "reload"]),
                    "steps": ["type": "array", "items": ["type": "object"], "maxItems": 30,
                              "description": "Actions to run in order instead of one, each an object with action and its fields."],
                    "ref": ToolSchema.string(),
                    "selector": ToolSchema.string("CSS."),
                    "x": ToolSchema.number("CSS pixels in the visible page."),
                    "y": ToolSchema.number(),
                    "to_ref": ToolSchema.string("For drag."),
                    "to_selector": ToolSchema.string("For drag."),
                    "text": ToolSchema.string("For type."),
                    "clear": ToolSchema.boolean("For type: replace the field's text."),
                    "submit": ToolSchema.boolean("For type: press Enter after."),
                    "key": ToolSchema.string("For press: such as Enter, ArrowDown or a character."),
                    "modifiers": ["type": "array", "items": ToolSchema.choice(["Alt", "Control", "Meta", "Shift"]),
                                  "description": "For click and press. Meta is Command."],
                    "values": ToolSchema.strings("For select: by value or label."),
                    "files": ToolSchema.strings("For upload: absolute paths, through a file input or the button that opens one."),
                    "click_count": ToolSchema.integer("1 to 3."),
                    "delta_x": ToolSchema.number(),
                    "delta_y": ToolSchema.number(),
                    "dialog": ToolSchema.choice(["accept", "dismiss"], "For dialogs the action opens. Default accept."),
                    "prompt_text": ToolSchema.string(),
                    "snapshot": ToolSchema.choice(["viewport", "page", "none"], "Default viewport; none: only the URL and new logs."),
                ],
                audience: .localAgents, reply: act
            ),
            Tool(
                name: "browser_wait_for",
                description: "Waits until the page meets every condition given, then returns a snapshot.",
                properties: [
                    "text": ToolSchema.string(),
                    "text_gone": ToolSchema.string(),
                    "selector": ToolSchema.string("Visible."),
                    "selector_gone": ToolSchema.string("Gone or hidden."),
                    "url_contains": ToolSchema.string(),
                    "timeout_seconds": ToolSchema.number("Default 10, at most 60."),
                ],
                audience: .localAgents, reply: waitFor
            ),
            Tool(
                name: "browser_logs",
                description: "Reads the page's console or network log, new since you last read it.",
                properties: [
                    "kind": ToolSchema.choice(["console", "network"], "Default console."),
                    "all": ToolSchema.boolean("Everything kept (the latest 300)."),
                    "problems_only": ToolSchema.boolean(),
                    "request": ToolSchema.string("A request ID, to read it in full with its bodies."),
                ],
                audience: .localAgents, reply: logs
            ),
            Tool(
                name: "browser_evaluate",
                description: "Runs JavaScript in the page as an async function body; `return` a JSON value (up to 64 KB) to read it.",
                properties: ["script": ToolSchema.string()],
                required: ["script"], audience: .localAgents, reply: evaluate
            ),
            Tool(
                name: "browser_viewport",
                description: "Sets the size the browser lays pages out at. A phone or tablet also gets its user agent, and the page reloads.",
                properties: [
                    "device": ToolSchema.choice(Self.devices),
                    "landscape": ToolSchema.boolean(),
                    "width": ToolSchema.number("CSS pixels, instead of a device."),
                    "height": ToolSchema.number(),
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
        var notes: [String] = []
        if let steps = call.arguments["steps"] {
            guard let steps = steps as? [[String: Any]], !steps.isEmpty else { throw Failure("Give steps as a list of actions, each an object with action and its fields.") }
            guard steps.count <= 30 else { throw Failure("A batch takes at most 30 steps.") }
            // Refs from the snapshot before the batch serve every step, as only a snapshot replaces them.
            for (index, step) in steps.enumerated() {
                // A step answers dialogs as the batch does, unless it says otherwise.
                let stepCall = ToolCall(arguments: step.merging(call.arguments.filter { ["dialog", "prompt_text"].contains($0.key) }) { own, _ in own },
                                        credential: call.credential, caller: call.caller)
                do {
                    if let note = try await acting(browser, stepCall, { try await perform(try stepCall.required("action"), stepCall, on: browser) }) {
                        notes.append("Step \(index + 1): \(note)")
                    }
                } catch {
                    let reason = (error as? Failure)?.message ?? error.localizedDescription
                    let done = index == 0 ? "No step ran" : index == 1 ? "Step 1 ran" : "Steps 1–\(index) ran"
                    let after = (try? await browser.snapshot(viewportOnly: true)) ?? browser.status()
                    throw Failure((notes + ["\(done); step \(index + 1) stopped the batch: \(reason)", after]).joined(separator: "\n\n"))
                }
            }
        } else {
            let action = try call.required("action")
            if let note = try await acting(browser, call, { try await perform(action, call, on: browser) }) { notes.append(note) }
        }
        let after: String
        switch call.string("snapshot") {
        case "page": after = try await browser.snapshot(viewportOnly: false)
        case "none": after = browser.status()
        default: after = try await browser.snapshot(viewportOnly: true)
        }
        return Reply(text: (notes + [after]).joined(separator: "\n\n"))
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
