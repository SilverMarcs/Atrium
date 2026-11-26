import AppKit

/// What agents do with a simulator, as `SimulatorTools` asks: read the screen
/// as an outline with refs, and touch, swipe, pinch, type and adjust like a
/// person. Points are in the screen's points as it's turned now.
extension SimulatorSession {
    // MARK: - Reading

    /// One line per element, top to bottom, with refs the next action can
    /// use, which replace the last snapshot's.
    func outline() async throws -> String {
        let device = simDevice
        let snapshot = try await Task.detached { try SimulatorAccessibility.shared.snapshot(of: device) }.value
        let size = turnedPointSize
        let screen = CGRect(origin: .zero, size: size)
        var lines = ["\(self.device.name) (\(self.device.runtime)), \(Int(size.width))×\(Int(size.height)) points"
            + (quarterTurns % 2 == 1 ? ", landscape" : "")]
        if let app = snapshot.app { lines.append("App: \(app)") }
        lines.append("")
        var refs: [String: SimulatorAccessibility.Element] = [:]
        var offScreen = 0
        for element in snapshot.elements {
            let frame = element.frame
            guard frame.width > 0, frame.height > 0 else { continue }
            // Layout groups with nothing to say only add lines, and the status bar's icons only noise.
            if element.label == nil, element.value == nil, SimulatorAccessibility.layoutRoles.contains(element.role) { continue }
            if element.role == "GenericElement", frame.maxY <= SimulatorAccessibility.statusBarHeight { continue }
            guard screen.intersects(frame) else {
                offScreen += 1
                continue
            }
            var line = Self.describe(element)
            if let value = element.value, value != element.label { line += " [value=\(Self.quoted(value))]" }
            if let identifier = element.identifier { line += " [id=\(identifier)]" }
            if !element.isEnabled { line += " [disabled]" }
            let ref = "e\(refs.count + 1)"
            refs[ref] = element
            lines.append(line + " [ref=\(ref)]")
        }
        self.refs = refs
        if refs.isEmpty { lines.append("(Nothing readable on screen; take a screenshot.)") }
        if offScreen > 0 { lines.append("(\(offScreen) more off screen; swipe to reach them.)") }
        return lines.joined(separator: "\n")
    }

    /// Reads the screen once in the background, so the agent's first snapshot is quick.
    func prepareReading() {
        let device = simDevice
        Task.detached(priority: .utility) { SimulatorAccessibility.shared.prepare(device) }
    }

    func element(ref: String) throws -> SimulatorAccessibility.Element {
        guard let element = refs[ref] else {
            throw SimulatorError("No element \(ref) in the latest snapshot; take a new one with simulator_snapshot.")
        }
        return element
    }

    /// The middle of the element a ref names, once a hit test shows it's still
    /// what a touch there reaches: something covering it, or moved into its
    /// place, refuses the touch, as a person would see before tapping.
    func point(ref: String) async throws -> CGPoint {
        let element = try element(ref: ref)
        let point = CGPoint(x: element.frame.midX, y: element.frame.midY)
        let device = simDevice
        guard let hit = await Task.detached(operation: { SimulatorAccessibility.shared.element(at: point, of: device) }).value,
              hit.frame.width > 0 else { return point }
        let target = element.frame.insetBy(dx: -2, dy: -2), found = hit.frame.insetBy(dx: -2, dy: -2)
        // A touch on a label lands on its button, and one on a button on its label.
        let inside = target.contains(hit.frame) || (found.contains(element.frame)
            && hit.frame.width * hit.frame.height <= element.frame.width * element.frame.height * 8)
        guard !inside else { return point }
        throw SimulatorError("\(ref) (\(Self.describe(element))) isn't what a touch there reaches now: \(Self.describe(hit)) is there"
            + (hit.role == "Key" || hit.role == "Keyboard" ? ", on the keyboard" : "")
            + ". Scroll it into view, close what covers it, or take a new snapshot.")
    }

    // MARK: - Touches

    func tap(at point: CGPoint, hold: Double = 0.06) async throws {
        let at = screenFraction(ofPoint: point)
        do {
            input.touch(.began, at: at)
            defer { input.touch(.ended, at: at) }
            try await Task.sleep(for: .seconds(hold))
        }
        await input.flush()
    }

    /// A finger, or two side by side across the way they move, from one point to another.
    func drag(from start: CGPoint, to end: CGPoint, fingers: Int = 1, duration: Double = 0.3) async throws {
        let horizontal = abs(end.x - start.x) > abs(end.y - start.y)
        let offset = horizontal ? CGPoint(x: 0, y: 40) : CGPoint(x: 40, y: 0)
        try await move(duration: duration) { t in
            let point = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
            return (point, fingers == 2 ? CGPoint(x: point.x + offset.x, y: point.y + offset.y) : nil)
        }
    }

    /// Two fingers around a point moving apart by `scale` (above 1 zooms in),
    /// starting close for a spread and wide for a pinch, on the screen.
    func pinch(around center: CGPoint, scale: Double, duration: Double = 0.5) async throws {
        let size = turnedPointSize
        let scale = CGFloat(min(max(scale, 0.1), 10))
        let room = min(center.x, size.width - center.x, center.y, size.height - center.y, 160) - 8
        let close = max(min(room / max(scale, 1 / scale), 60), 12)
        let (from, to) = scale >= 1 ? (close, min(close * scale, room)) : (min(close / scale, room), close)
        try await move(duration: duration) { t in
            let spread = from + (to - from) * t
            return (CGPoint(x: center.x - spread, y: center.y), CGPoint(x: center.x + spread, y: center.y))
        }
    }

    /// Moves one or two fingers along `path` (0 to 1 in, points out), a step every frame.
    private func move(duration: Double, along path: (CGFloat) -> (CGPoint, CGPoint?)) async throws {
        let duration = min(max(duration, 0.05), 5)
        let steps = max(Int(duration / 0.016), 2)
        func fingers(_ t: CGFloat) -> (CGPoint, CGPoint?) {
            let (first, second) = path(t)
            return (screenFraction(ofPoint: first), second.map(screenFraction(ofPoint:)))
        }
        var current = fingers(0)
        do {
            input.touch(.began, at: current.0, second: current.1)
            defer { input.touch(.ended, at: current.0, second: current.1) }
            for step in 1...steps {
                try await Task.sleep(for: .seconds(duration / Double(steps)))
                current = fingers(CGFloat(step) / CGFloat(steps))
                input.touch(.moved, at: current.0, second: current.1)
            }
        }
        await input.flush()
    }

    // MARK: - Keys

    /// Types text on a US keyboard, or pastes it when a character isn't on one.
    func type(_ text: String, submit: Bool) async throws {
        if let strokes = SimulatorKeys.strokes(for: text) {
            for stroke in strokes {
                try Task.checkCancellation()
                await SimulatorKeys.press(stroke.usage, modifiers: stroke.shift ? [SimulatorKeys.shift] : [], on: input)
            }
        } else {
            try await SimulatorKit.simctl(["pbcopy", udid], input: Data(text.utf8))
            try Task.checkCancellation()
            await SimulatorKeys.press(SimulatorKeys.v, modifiers: [SimulatorKeys.command], on: input)
        }
        try Task.checkCancellation()
        if submit { await SimulatorKeys.press(SimulatorKeys.returnKey, on: input) }
    }

    // MARK: - Sliders

    /// Steps a slider toward a percentage, as VoiceOver adjusts one, and
    /// returns where it landed: sliders that move in steps stop at the nearest.
    func setSlider(_ slider: SimulatorAccessibility.Element, to percent: Double) async throws -> Double {
        guard var current = Self.percent(slider.value) else { throw SimulatorError("It has no value to set; tap or swipe it instead.") }
        let device = simDevice
        let up = percent > current
        var frame = slider.frame
        func adjust(up: Bool, step: Bool) async -> Double? {
            let at = frame
            if let value = await Task.detached(operation: {
                SimulatorSession.percent(SimulatorAccessibility.shared.adjust(in: at, of: device, up: up, step: step))
            }).value { return value }
            // What the slider changes can move it, as text size does: find it again.
            let elements = await Task.detached(operation: { try? SimulatorAccessibility.shared.snapshot(of: device, probing: false) }).value?.elements ?? []
            let same = elements.filter { $0.role == slider.role && $0.identifier == slider.identifier && $0.label == slider.label }
            guard let moved = same.min(by: { abs($0.frame.midY - at.midY) < abs($1.frame.midY - at.midY) }) else { return nil }
            frame = moved.frame
            let again = frame
            return await Task.detached(operation: {
                SimulatorSession.percent(SimulatorAccessibility.shared.adjust(in: again, of: device, up: up, step: step))
            }).value
        }
        for _ in 0..<100 where abs(current - percent) > 0.5 {
            // The value can read as before for a while after a step, as the
            // app lays out what it changed, and a step sent meanwhile is lost.
            var next = await adjust(up: up, step: true)
            for attempt in 0..<8 where next == current {
                try await Task.sleep(for: .milliseconds(150))
                next = await adjust(up: up, step: attempt == 4)
            }
            guard let next, next != current else { break }
            // That step passed the value: go back when the side before was nearer.
            if up ? next > percent : next < percent {
                current = abs(next - percent) > abs(current - percent) ? await adjust(up: !up, step: true) ?? next : next
                break
            }
            current = next
        }
        return current
    }

    /// A slider's value as a percentage: "50%", or a fraction such as "0.5".
    nonisolated static func percent(_ value: String?) -> Double? {
        guard let value, let number = Double(value.filter { $0.isNumber || $0 == "." || $0 == "-" }) else { return nil }
        return value.contains("%") || number > 1 ? number : number * 100
    }

    // MARK: - Describing

    /// Such as `button "Save"`.
    static func describe(_ element: SimulatorAccessibility.Element) -> String {
        roleName(element.role) + (element.label.map { " " + quoted($0) } ?? "")
    }

    /// `TextField` as `text-field`, `StaticText` as `text`.
    private static func roleName(_ role: String) -> String {
        if role == "StaticText" { return "text" }
        if role.isEmpty { return "element" }
        var name = ""
        for character in role {
            if character.isUppercase, !name.isEmpty { name += "-" }
            name += character.lowercased()
        }
        return name
    }

    private static func quoted(_ text: String) -> String {
        let single = text.replacingOccurrences(of: "\n", with: " ")
        return "\"" + (single.count > 120 ? String(single.prefix(120)) + "…" : single) + "\""
    }
}
