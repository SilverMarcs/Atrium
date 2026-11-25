import CoreGraphics
import Foundation

/// The tools that show a simulator beside a chat, for the agents this Mac
/// runs: the chat's Simulator tab shows the one its agent opens, live, and
/// the user can use it there too. Agents read the screen as text with
/// element refs and act with real touches and keys, as with the browser
/// tools; other simulator tools work on it too, and the tab shows them.
@MainActor
struct SimulatorTools {
    typealias Tool = ToolServer.Tool
    typealias ToolCall = ToolServer.ToolCall
    typealias Failure = ToolServer.Failure
    typealias Reply = ToolServer.Reply

    let simulators: AgentSimulators

    private static let actions = ["tap", "long_press", "swipe", "pinch", "type", "key", "set_value", "button", "rotate",
                                  "open_url", "launch"]
    private static let udidProperty = ToolSchema.string(
        "Use this booted simulator without showing it in your chat, as for experiments the user didn't ask to watch.")

    var tools: [Tool] {
        [
            Tool(
                name: "simulator_list",
                description: "Lists Xcode's simulators with their UDIDs and states, and which one your chat shows.",
                properties: [:], audience: .localAgents, readsOnly: true, run: list
            ),
            Tool(
                name: "simulator_open",
                description: """
                    Shows a simulator in your chat's Simulator tab, booting it if it's off, where the user watches it live \
                    and can use it. Open the simulator you run an app in for the user, as soon as you have its UDID; skip \
                    it for experiments the user didn't ask to watch and pass the UDID to the other simulator_* tools. \
                    Drive simulators with simulator_snapshot and simulator_act, not computer use, unless the user names \
                    another tool.
                    """,
                properties: ["udid": ToolSchema.string()],
                required: ["udid"], audience: .localAgents, alwaysLoads: true, reply: open
            ),
            Tool(
                name: "simulator_snapshot",
                description: """
                    Reads the screen as a text outline: the app in front, then one element per line, top to bottom, with \
                    a ref, such as e12, to act on. Refs last until the next snapshot or action.
                    """,
                properties: [
                    "udid": Self.udidProperty,
                    "screenshot": ToolSchema.boolean("Also return a PNG in points, saved to a file too. Only when how it looks matters."),
                ],
                audience: .localAgents, readsOnly: true, reply: snapshot
            ),
            Tool(
                name: "simulator_act",
                description: """
                    Acts on the screen with real touches and keys, waits for it to settle, and returns a snapshot. Target \
                    an element by ref, which is refused when something else now covers it, or a point by x and y in \
                    points. swipe goes in a direction (up scrolls down) or to to_x and to_y; set_value moves a slider; \
                    type taps ref first when given. `steps` runs several actions, all using refs from the snapshot \
                    before, and stops at the first that fails.
                    """,
                properties: [
                    "action": ToolSchema.choice(Self.actions),
                    "steps": ["type": "array", "items": ["type": "object"], "maxItems": 30,
                              "description": "Actions to run in order instead of one, each an object with action and its fields."],
                    "udid": Self.udidProperty,
                    "ref": ToolSchema.string(),
                    "x": ToolSchema.number("Points from the screen's left, as it's turned now."),
                    "y": ToolSchema.number(),
                    "to_x": ToolSchema.number("For swipe."),
                    "to_y": ToolSchema.number(),
                    "direction": ToolSchema.choice(["up", "down", "left", "right"], "For swipe; left or right for rotate."),
                    "fingers": ToolSchema.integer("For swipe: 1 or 2."),
                    "scale": ToolSchema.number("For pinch: 2 spreads to zoom in, 0.5 pinches to zoom out."),
                    "duration": ToolSchema.number("Seconds, for long_press, swipe and pinch."),
                    "value": ToolSchema.number("For set_value: 0 to 100."),
                    "text": ToolSchema.string("For type; text a US keyboard can't type is pasted."),
                    "submit": ToolSchema.boolean("For type: press Return after."),
                    "key": ToolSchema.string("For key: return, escape, delete, tab, space, an arrow, or a character."),
                    "modifiers": ["type": "array", "items": ToolSchema.choice(["command", "shift", "option", "control"]),
                                  "description": "For key."],
                    "button": ToolSchema.choice(SimulatorInput.Button.named.keys.sorted()),
                    "url": ToolSchema.string("For open_url: a web address or deep link."),
                    "bundle_id": ToolSchema.string("For launch."),
                    "snapshot": ToolSchema.boolean("Default true."),
                    "screenshot": ToolSchema.boolean("Also return a PNG."),
                ],
                audience: .localAgents, reply: act
            ),
            Tool(
                name: "simulator_close",
                description: "Takes the simulator out of your chat's Simulator tab. It keeps running unless you shut it down.",
                properties: ["shutdown": ToolSchema.boolean()],
                audience: .localAgents, run: close
            ),
        ]
    }

    // MARK: - Tools

    private func list(_ call: ToolCall) async throws -> String {
        try requireXcode()
        await simulators.refreshDevices()
        let shown = call.caller.flatMap { simulators.shown[$0] }
        let lines = simulators.devices.map { device in
            "- \(device.name) (\(device.runtime)), \(device.state.title.lowercased()): \(device.udid)"
                + (device.udid == shown ? " ← your chat shows this one" : "")
        }
        return lines.isEmpty ? "Xcode has no simulators." : lines.joined(separator: "\n")
    }

    private func open(_ call: ToolCall) async throws -> Reply {
        try requireXcode()
        let caller = try call.requiredCaller()
        let udid = try call.required("udid").uppercased()
        guard let session = simulators.show(udid, in: caller, byAgent: true) else {
            throw Failure("No simulator has UDID \(udid); simulator_list lists them.")
        }
        if session.device.state == .shutdown {
            do { try await session.boot() } catch { throw Failure("\(session.device.name) didn't boot: \(error.localizedDescription)") }
        }
        await simulators.refreshDevices()
        session.input.prepare()
        session.prepareReading()
        let size = session.turnedPointSize
        return Reply(text: """
            Your chat's Simulator tab shows \(session.device.name) (\(session.device.runtime), \(session.device.state.title.lowercased()), \
            UDID \(udid)). Its screen is \(Int(size.width))×\(Int(size.height)) points. Read it with simulator_snapshot.
            """)
    }

    private func snapshot(_ call: ToolCall) async throws -> Reply {
        let session = try bootedSession(call)
        return try await reply(for: session, outline: true, screenshot: call.bool("screenshot") == true)
    }

    private func act(_ call: ToolCall) async throws -> Reply {
        let session = try bootedSession(call)
        session.screen.watch()
        var notes: [String] = []
        if let steps = call.arguments["steps"] as? [[String: Any]], !steps.isEmpty {
            guard steps.count <= 30 else { throw Failure("A batch takes at most 30 steps.") }
            // Refs from the snapshot before the batch serve every step; checks catch any that moved.
            for (index, step) in steps.enumerated() {
                do {
                    let note = try await perform(ToolCall(arguments: step, credential: call.credential, caller: call.caller), on: session)
                    if let note { notes.append("Step \(index + 1): \(note)") }
                } catch {
                    session.refs = [:]
                    let done = index == 0 ? "No step ran" : index == 1 ? "Step 1 ran" : "Steps 1–\(index) ran"
                    let after = try? await session.outline()
                    throw Failure("\(done); step \(index + 1) stopped the batch: \(error.localizedDescription)" + (after.map { "\n\n" + $0 } ?? ""))
                }
                if index < steps.count - 1 { await session.screen.waitUntilStill(quiet: .milliseconds(300), timeout: .seconds(3)) }
            }
        } else if let note = try await perform(call, on: session) {
            notes.append(note)
        }
        // Refs name what was on screen before; the action may have moved it.
        session.refs = [:]

        let outline = call.bool("snapshot") ?? true
        let screenshot = call.bool("screenshot") == true
        guard outline || screenshot else { return Reply(text: (notes + ["Done."]).joined(separator: "\n")) }
        // Lets the screen settle: animations, keyboards, loads.
        await session.screen.waitUntilStill()
        var result = try await reply(for: session, outline: outline, screenshot: screenshot)
        if !notes.isEmpty { result.text = notes.joined(separator: "\n") + "\n\n" + result.text }
        return result
    }

    /// Performs one action; returns a note when there's more to say than the snapshot shows.
    private func perform(_ call: ToolCall, on session: SimulatorSession) async throws -> String? {
        let action = try call.required("action")
        let size = session.turnedPointSize
        let middle = CGPoint(x: size.width / 2, y: size.height / 2)

        /// The element's middle or the point given, in points.
        func target() async throws -> CGPoint? {
            if let ref = call.string("ref") { return try await session.point(ref: ref) }
            guard let x = call.double("x"), let y = call.double("y") else { return nil }
            guard (0...size.width).contains(x), (0...size.height).contains(y) else {
                throw Failure("(\(x), \(y)) is off the screen, which is \(Int(size.width))×\(Int(size.height)) points.")
            }
            return CGPoint(x: x, y: y)
        }

        switch action {
        case "tap", "long_press":
            guard let point = try await target() else { throw Failure("\(action) needs ref, or x and y.") }
            try await session.tap(at: point, hold: action == "tap" ? 0.06 : min(max(call.double("duration") ?? 0.8, 0.3), 10))
        case "swipe":
            let start = try await target() ?? middle
            let end: CGPoint
            if let x = call.double("to_x"), let y = call.double("to_y") {
                end = CGPoint(x: x, y: y)
            } else {
                // Most of the way across the screen, staying on it.
                let reach = (call.string("direction") == "left" || call.string("direction") == "right" ? size.width : size.height) * 0.6
                switch call.string("direction") {
                case "up": end = CGPoint(x: start.x, y: max(start.y - reach, 4))
                case "down": end = CGPoint(x: start.x, y: min(start.y + reach, size.height - 4))
                case "left": end = CGPoint(x: max(start.x - reach, 4), y: start.y)
                case "right": end = CGPoint(x: min(start.x + reach, size.width - 4), y: start.y)
                default: throw Failure("swipe needs a direction, or to_x and to_y.")
                }
            }
            try await session.drag(from: start, to: end, fingers: call.int("fingers") == 2 ? 2 : 1, duration: call.double("duration") ?? 0.3)
        case "pinch":
            try await session.pinch(around: try await target() ?? middle, scale: call.double("scale") ?? 2,
                                    duration: call.double("duration") ?? 0.5)
        case "set_value":
            guard let ref = call.string("ref") else { throw Failure("set_value needs the slider's ref.") }
            guard let percent = call.double("value"), (0...100).contains(percent) else { throw Failure("set_value needs a value from 0 to 100.") }
            let landed = try await session.setSlider(try session.element(ref: ref), to: percent)
            return "\(ref) reads \(Int(landed.rounded()))%" + (abs(landed - percent) > 0.5 ? ", the nearest step." : ".")
        case "type":
            guard let text = call.arguments["text"] as? String, !text.isEmpty else { throw Failure("type needs text.") }
            if let point = try await target() {
                try await session.tap(at: point)
                // Lets the field take focus and its keyboard come up.
                try await Task.sleep(for: .milliseconds(400))
            }
            try await session.type(text, submit: call.bool("submit") == true)
        case "key":
            let key = try call.required("key")
            guard let stroke = SimulatorKeys.usage(named: key) else { throw Failure("Diffs doesn't know the key \(key).") }
            let modifiers = call.strings("modifiers").compactMap(SimulatorKeys.modifierUsage)
            await SimulatorKeys.press(stroke.usage, modifiers: modifiers + (stroke.shift ? [SimulatorKeys.shift] : []), on: session.input)
        case "button":
            let name = try call.required("button")
            guard let button = SimulatorInput.Button.named[name] else {
                throw Failure("button is one of \(SimulatorInput.Button.named.keys.sorted().joined(separator: ", ")).")
            }
            session.input.press(button, hold: name == "siri" ? 0.4 : 0.1)
            await session.input.flush()
        case "rotate":
            session.rotate(clockwise: call.string("direction") != "left")
        case "open_url":
            do { try await session.open(url: try call.required("url")) } catch let failure as Failure { throw failure } catch {
                throw Failure("The simulator couldn't open it: \(error.localizedDescription)")
            }
        case "launch":
            do { try await SimulatorKit.simctl(["launch", session.udid, try call.required("bundle_id")]) } catch let failure as Failure {
                throw failure
            } catch {
                throw Failure("It didn't launch: \(error.localizedDescription)")
            }
        default:
            throw Failure("action is one of \(Self.actions.joined(separator: ", ")).")
        }
        return nil
    }

    /// The snapshot outline and the screenshot, as asked.
    private func reply(for session: SimulatorSession, outline: Bool, screenshot: Bool) async throws -> Reply {
        var text = ""
        if outline {
            do { text = try await session.outline() } catch { throw Failure("Couldn't read the screen: \(error.localizedDescription)") }
        }
        var png: Data?
        if screenshot {
            let data = try await session.screenshot(points: true)
            let file = try save(data)
            png = data
            text += (text.isEmpty ? "" : "\n\n") + "Screenshot saved to \(file.path(percentEncoded: false))"
        }
        return Reply(text: text, png: png)
    }

    private func close(_ call: ToolCall) async throws -> String {
        let caller = try call.requiredCaller()
        guard let session = simulators.session(for: caller) else { return "Your chat shows no simulator." }
        simulators.close(caller)
        if call.bool("shutdown") == true {
            try await session.shutDown()
            return "\(session.device.name) is out of your chat and shut down."
        }
        return "\(session.device.name) is out of your chat and still running."
    }

    // MARK: - Helpers

    private func requireXcode() throws {
        guard SimulatorKit.isAvailable else { throw Failure("Simulators need Xcode, which this Mac doesn't have selected.") }
    }

    /// The booted simulator the call names, or else the one its chat shows.
    private func bootedSession(_ call: ToolCall) throws -> SimulatorSession {
        let session: SimulatorSession
        if let udid = call.string("udid")?.uppercased() {
            guard let found = simulators.session(udid: udid) else { throw Failure("No simulator has UDID \(udid); simulator_list lists them.") }
            if found.lastAgentUse == .distantPast { found.prepareReading() }
            found.lastAgentUse = .now
            session = found
        } else {
            let caller = try call.requiredCaller()
            guard let found = simulators.session(for: caller) else {
                throw Failure("Your chat shows no simulator; open one with simulator_open.")
            }
            simulators.noteAgentUse(by: caller)
            session = found
        }
        guard session.isBooted else { throw Failure("\(session.device.name) is shut down; boot it with simulator_open.") }
        return session
    }

    private func save(_ png: Data) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "Diffs Simulator Screenshots", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "\(UUID().uuidString.prefix(8)).png")
        try png.write(to: file)
        return file
    }
}

private extension ToolServer.ToolCall {
    /// The chat a local agent calls from.
    func requiredCaller() throws -> String {
        guard let caller else { throw ToolServer.Failure("Diffs couldn't tell which of its chats this call comes from.") }
        return caller
    }
}
