import AppKit

/// Reads what's on a simulator's screen through its accessibility tree: the
/// private AccessibilityPlatformTranslation framework turns the simulator's
/// accessibility into Mac accessibility elements, asking CoreSimulator for
/// each attribute it needs. A walk from the frontmost app finds most
/// elements; probing a grid of points finds those that scroll views and
/// other containers keep out of the walk.
///
/// Every call blocks while it asks the simulator, so make them off the main
/// thread. `device` is the simulator's `SimDevice`.
///
/// After serve-sim's AccessibilityBridge (https://github.com/EvanBacon/serve-sim,
/// Apache-2.0), itself ported from idb's FBSimulatorAccessibilityCommands (MIT).
nonisolated final class SimulatorAccessibility: NSObject, @unchecked Sendable {
    struct Element: Sendable {
        /// Such as "Button", "TextField" or "StaticText".
        let role: String
        let label: String?
        let value: String?
        let identifier: String?
        let isEnabled: Bool
        /// In points, from the screen's top left.
        let frame: CGRect

        fileprivate init(_ object: NSObject) {
            role = SimulatorAccessibility.role(of: object)
            label = SimulatorAccessibility.string(object, "accessibilityLabel")
            value = SimulatorAccessibility.string(object, "accessibilityValue")
            identifier = SimulatorAccessibility.string(object, "accessibilityIdentifier")
            isEnabled = (object.value(forKey: "accessibilityEnabled") as? NSNumber)?.boolValue ?? true
            frame = SimulatorAccessibility.frame(of: object)
        }
    }

    struct Snapshot: Sendable {
        /// The frontmost app's name.
        let app: String?
        let elements: [Element]
    }

    static let shared = SimulatorAccessibility()

    /// Roles iOS gives views that lay others out: they say nothing themselves,
    /// and can hold elements the walk doesn't reach.
    static let layoutRoles: Set<String> = [
        "", "Application", "Window", "Group", "ScrollArea", "Table", "Collection", "Outline", "List",
        "WebArea", "LayoutArea", "SplitGroup", "TabGroup", "Toolbar", "GenericElement", "Unknown",
    ]
    /// The status bar's height in points, whose icons iOS reads either way.
    static let statusBarHeight: CGFloat = 60

    private static let maximumElements = 400
    private static let maximumProbes = 500
    /// Small enough to land in a list row or a home screen icon.
    private static let gridStep: CGFloat = 40

    private let lock = NSLock()
    /// One read at a time: the translator is shared, and its delegate
    /// answers for whichever simulator the current read is of.
    private let readLock = NSLock()
    private let replies = DispatchQueue(label: "Atrium.SimulatorAccessibility", qos: .userInitiated)
    private var devices: [String: NSObject] = [:]
    private var translator: NSObject?
    /// Apps, by simulator and name, that stayed empty after loading
    /// accessibility: ones with nothing to read, which aren't waited on again.
    private var empty: Set<String> = []

    /// The frontmost app's elements, top to bottom.
    func snapshot(of device: NSObject, probing: Bool = true) throws -> Snapshot {
        readLock.lock()
        defer { readLock.unlock() }
        let translator = try loadedTranslator()
        var tokens: [String] = []
        defer { lock.withLock { for token in tokens { devices[token] = nil } } }

        typealias Frontmost = @convention(c) (AnyObject, Selector, UInt32, NSString) -> AnyObject?
        let frontmostSelector = NSSelectorFromString("frontmostApplicationWithDisplayId:bridgeDelegateToken:")
        func read() -> (root: NSObject, reader: Reader)? {
            // A token keeps what it read, so a read after accessibility loads needs a new one.
            let token = register(device)
            tokens.append(token)
            guard let translation = unsafeBitCast(translator.method(for: frontmostSelector), to: Frontmost.self)(
                translator, frontmostSelector, 0, token as NSString) as? NSObject,
                let root = element(for: translation, token: token, translator: translator) else { return nil }
            var reader = Reader(token: token)
            reader.walk(root, depth: 0)
            return (root, reader)
        }
        /// Whether the app shows anything below the status bar.
        func hasContent(_ read: (root: NSObject, reader: Reader)?) -> Bool {
            read?.reader.elements.contains { $0.frame.minY >= Self.statusBarHeight && $0.frame.width > 0 } == true
        }
        var found = read()
        // An app launched since accessibility was last loaded reads as empty
        // until it's loaded again. A load asked for in the app's first
        // seconds doesn't take, so it's asked again until one does.
        let udid = (device.value(forKey: "UDID") as? NSUUID)?.uuidString ?? ""
        let app = "\(udid)|\(found.flatMap { Self.string($0.root, "accessibilityLabel") } ?? "")"
        if !hasContent(found), !empty.contains(app) {
            let deadline = Date().addingTimeInterval(8)
            while !hasContent(found), Date() < deadline {
                loadAccessibility(in: device)
                for _ in 0..<4 {
                    found = read()
                    if hasContent(found) { break }
                    Thread.sleep(forTimeInterval: 0.25)
                }
            }
            if !hasContent(found) { empty.insert(app) }
        }
        if hasContent(found) { empty.remove(app) }
        guard let (root, walked) = found else { throw SimulatorError("The simulator has no app on screen yet.") }
        var reader = walked
        let screen = Self.frame(of: root)
        if probing, screen.width > 1, screen.height > 1 {
            probeGrid(screen, reader: &reader, translator: translator)
        }
        // The grid can reach an element the walk found, through a new object.
        var seen = Set<String>()
        let unique = reader.elements.filter { element in
            seen.insert("\(element.role)|\(element.label ?? "")|\(element.value ?? "")|\(element.frame)").inserted
        }
        let name = Self.string(root, "accessibilityLabel")?.trimmingCharacters(in: .whitespaces)
        return Snapshot(app: name?.isEmpty == false ? name : nil, elements: unique.sorted {
            abs($0.frame.minY - $1.frame.minY) > 4 ? $0.frame.minY < $1.frame.minY : $0.frame.minX < $1.frame.minX
        })
    }

    /// The element at a point of the screen, in points: what a tap there would land on.
    func element(at point: CGPoint, of device: NSObject) -> Element? {
        reading(device) { translator, token in
            object(at: point, token: token, translator: translator).map(Element.init)
        }
    }

    /// Steps the adjustable element in `frame`, such as a slider, up or down
    /// as VoiceOver's swipes do, and returns its value after; with `step`
    /// false it only reads the value. The frame is read at a few points
    /// across it, since a thumb or label can answer for the middle. Nil
    /// when nothing there has a value.
    func adjust(in frame: CGRect, of device: NSObject, up: Bool, step: Bool = true) -> String? {
        reading(device) { translator, token in
            for fraction in [0.5, 0.3, 0.7, 0.15, 0.85] {
                let point = CGPoint(x: frame.minX + frame.width * fraction, y: frame.midY)
                guard let element = object(at: point, token: token, translator: translator) as? NSAccessibilityElement,
                      Self.string(element, "accessibilityValue") != nil else { continue }
                if step { _ = up ? element.accessibilityPerformIncrement() : element.accessibilityPerformDecrement() }
                return Self.string(element, "accessibilityValue")
            }
            return nil
        }
    }

    /// Gets a simulator ready to read, ahead of the agent's first snapshot:
    /// the translator in use and the frontmost app's accessibility loaded.
    func prepare(_ device: NSObject) {
        _ = try? snapshot(of: device, probing: false)
    }

    // MARK: - Reading

    private struct Reader {
        let token: String
        var elements: [Element] = []
        var visited = Set<ObjectIdentifier>()
        /// Elements already read, by role and frame: probes reach them through new objects.
        var seen = Set<String>()
        /// Frames of elements that hold nothing more: points inside them need no probe.
        var leaves: [CGRect] = []

        static func key(_ role: String, _ frame: CGRect) -> String {
            "\(role)|\(Int(frame.minX)),\(Int(frame.minY)),\(Int(frame.width)),\(Int(frame.height))"
        }

        mutating func walk(_ object: NSObject, depth: Int) {
            guard elements.count < SimulatorAccessibility.maximumElements, depth < 80,
                  visited.insert(ObjectIdentifier(object)).inserted else { return }
            SimulatorAccessibility.stamp(object, token: token)
            let element = Element(object)
            seen.insert(Self.key(element.role, element.frame))
            let children = (object as? NSAccessibilityElement)?.accessibilityChildren() ?? []
            if depth > 0 { elements.append(element) }
            if children.isEmpty, max(element.frame.width, element.frame.height) < 250,
               !SimulatorAccessibility.layoutRoles.contains(element.role) {
                leaves.append(element.frame)
            }
            for child in children {
                guard let child = child as? NSObject else { continue }
                walk(child, depth: depth + 1)
            }
        }

        func covers(_ point: CGPoint) -> Bool {
            leaves.contains { $0.contains(point) }
        }
    }

    /// Asks what's at points across the screen, skipping points inside
    /// elements already found, which keeps the cost to the elements there are.
    private func probeGrid(_ screen: CGRect, reader: inout Reader, translator: NSObject) {
        var probes = 0
        var probed = Set<String>()

        /// Asks what's at a point; returns whether it found an element not read before.
        func probe(_ point: CGPoint) -> Bool {
            guard probes < Self.maximumProbes, reader.elements.count < Self.maximumElements,
                  !reader.covers(point), probed.insert("\(Int(point.x)),\(Int(point.y))").inserted else { return false }
            probes += 1
            guard let element = object(at: point, token: reader.token, translator: translator) else { return false }
            let frame = Self.frame(of: element)
            // The app or its window: nothing new, and nothing to skip by.
            if abs(frame.width - screen.width) < 1, abs(frame.height - screen.height) < 1 { return false }
            let isSmall = max(frame.width, frame.height) < 250 && frame.width > 0
            guard !reader.seen.contains(Reader.key(Self.role(of: element), frame)) else {
                // Read before: the point is its, and so is the rest of it when it's small.
                if isSmall { reader.leaves.append(frame) }
                return false
            }
            reader.walk(element, depth: 1)
            if isSmall { reader.leaves.append(frame) }
            return true
        }

        // Bars, sheets, keyboards and tab bars hide their contents from the
        // walk most often, so the top and bottom are probed closely and the
        // middle loosely, then closely around whatever the loose pass finds.
        let step = Self.gridStep
        let topBand = screen.minY + 110, bottomBand = screen.maxY - 170
        let columns = stride(from: screen.minX + step / 2, to: screen.maxX, by: step).map { $0 }
        var foundRows: [CGFloat] = []
        for y in stride(from: screen.minY + step / 2, to: screen.maxY, by: step) {
            let close = y < topBand || y > bottomBand
            let everyOther = Int((y - screen.minY) / step) % 2 == 0
            guard close || everyOther else { continue }
            for (index, x) in columns.enumerated() where close || index % 2 == 0 {
                if probe(CGPoint(x: x, y: y)), !close { foundRows.append(y) }
            }
        }
        for row in foundRows {
            for y in [row - step, row, row + step] where y > screen.minY && y < screen.maxY {
                for x in columns { _ = probe(CGPoint(x: x, y: y)) }
            }
        }
    }

    /// Runs one read of a simulator with its own token, one read at a time.
    private func reading<T>(_ device: NSObject, _ read: (NSObject, String) -> T?) -> T? {
        readLock.lock()
        defer { readLock.unlock() }
        guard let translator = try? loadedTranslator() else { return nil }
        let token = register(device)
        defer { lock.withLock { devices[token] = nil } }
        return read(translator, token)
    }

    /// A new token that routes the translator's requests to `device`.
    private func register(_ device: NSObject) -> String {
        let token = UUID().uuidString
        lock.withLock { devices[token] = device }
        return token
    }

    /// The deepest element at a point, as a hit test finds it.
    private func object(at point: CGPoint, token: String, translator: NSObject) -> NSObject? {
        typealias ObjectAtPoint = @convention(c) (AnyObject, Selector, CGPoint, UInt32, NSString) -> AnyObject?
        let selector = NSSelectorFromString("objectAtPoint:displayId:bridgeDelegateToken:")
        guard translator.responds(to: selector),
              let translation = unsafeBitCast(translator.method(for: selector), to: ObjectAtPoint.self)(
                translator, selector, point, 0, token as NSString) as? NSObject else { return nil }
        return element(for: translation, token: token, translator: translator)
    }

    private func element(for translation: NSObject, token: String, translator: NSObject) -> NSObject? {
        translation.setValue(token, forKey: "bridgeDelegateToken")
        typealias MacElement = @convention(c) (AnyObject, Selector, AnyObject) -> AnyObject?
        let selector = NSSelectorFromString("macPlatformElementFromTranslation:")
        let element = unsafeBitCast(translator.method(for: selector), to: MacElement.self)(translator, selector, translation) as? NSObject
        element.map { Self.stamp($0, token: token) }
        return element
    }

    /// The translator makes new translation objects as children are read,
    /// and each needs the token to reach the right simulator.
    private static func stamp(_ element: NSObject, token: String) {
        (element.value(forKey: "translation") as? NSObject)?.setValue(token, forKey: "bridgeDelegateToken")
    }

    private static func string(_ object: NSObject, _ key: String) -> String? {
        let value = object.value(forKey: key)
        let text = (value as? String) ?? (value as? NSAttributedString)?.string ?? value.map { "\($0)" }
        guard let text, !text.isEmpty else { return nil }
        return text
    }

    private static func role(of object: NSObject) -> String {
        var role = string(object, "accessibilityRole") ?? ""
        if role.hasPrefix("AX") { role.removeFirst(2) }
        return role
    }

    private static func frame(of object: NSObject) -> CGRect {
        (object as? NSAccessibilityElement)?.accessibilityFrame() ?? .zero
    }

    /// iOS 27 loads accessibility into an app only once something asks for
    /// automation: a short-lived XCUIAutomation session that asks the
    /// simulator to load it, as idb does before each read. Without it, an
    /// app launched since the last such session reads as empty.
    private func loadAccessibility(in device: NSObject) {
        let developer = SimulatorKit.developerDir
        for name in ["XCTDaemonControl", "XCUIAutomation"] {
            _ = dlopen("\(developer)/../SharedFrameworks/\(name).framework/\(name)", RTLD_NOW)
        }
        guard let providerClass = NSClassFromString("XCUIDeviceRemoteDaemonConnectionProvider") as? NSObject.Type,
              let sessionClass = NSClassFromString("XCUIDeviceRemoteAutomationSession") as? NSObject.Type,
              let provider = providerClass.perform(NSSelectorFromString("connectionProviderForSimDevice:"), with: device)?
                .takeUnretainedValue() else { return }

        final class Box: @unchecked Sendable { var session: NSObject? }
        let box = Box()
        let created = DispatchSemaphore(value: 0)
        let completion: @convention(block) (AnyObject?, NSError?) -> Void = { session, _ in
            box.session = session as? NSObject
            created.signal()
        }
        typealias Request = @convention(c) (AnyObject, Selector, AnyObject, AnyObject) -> Void
        let requestSelector = NSSelectorFromString("requestSessionWithDaemonConnectionProvider:completion:")
        guard sessionClass.responds(to: requestSelector) else { return }
        unsafeBitCast(sessionClass.method(for: requestSelector), to: Request.self)(sessionClass, requestSelector, provider, completion as AnyObject)
        guard created.wait(timeout: .now() + 5) == .success, let session = box.session else { return }
        defer { session.perform(NSSelectorFromString("invalidate")) }

        let enableSelector = NSSelectorFromString("enableAutomationModeWithError:")
        if session.responds(to: enableSelector) {
            typealias Enable = @convention(c) (AnyObject, Selector, AutoreleasingUnsafeMutablePointer<NSError?>) -> ObjCBool
            var error: NSError?
            _ = unsafeBitCast(session.method(for: enableSelector), to: Enable.self)(session, enableSelector, &error)
        }
        let loadSelector = NSSelectorFromString("loadAccessibilityWithTimeout:reply:")
        guard session.responds(to: loadSelector) else { return }
        let loaded = DispatchSemaphore(value: 0)
        let reply: @convention(block) (ObjCBool, NSError?) -> Void = { _, _ in loaded.signal() }
        typealias Load = @convention(c) (AnyObject, Selector, Double, AnyObject) -> Void
        unsafeBitCast(session.method(for: loadSelector), to: Load.self)(session, loadSelector, 5, reply as AnyObject)
        _ = loaded.wait(timeout: .now() + 5)
    }

    private func loadedTranslator() throws -> NSObject {
        try lock.withLock {
            if let translator { return translator }
            let path = "/System/Library/PrivateFrameworks/AccessibilityPlatformTranslation.framework/AccessibilityPlatformTranslation"
            guard dlopen(path, RTLD_NOW) != nil,
                  let translatorClass = NSClassFromString("AXPTranslator") as? NSObject.Type,
                  let shared = translatorClass.perform(NSSelectorFromString("sharedInstance"))?.takeUnretainedValue() as? NSObject
            else { throw SimulatorError("macOS's accessibility translation isn't available.") }
            // Requests carry a token naming the simulator, as idb routes them.
            shared.setValue(self, forKey: "bridgeTokenDelegate")
            shared.setValue(true, forKey: "supportsDelegateTokens")
            shared.setValue(true, forKey: "accessibilityEnabled")
            translator = shared
            return shared
        }
    }

    // MARK: - Translator delegate

    /// Answers one attribute request by asking the simulator and waiting for
    /// its reply, as the translator reads attributes synchronously.
    @objc(accessibilityTranslationDelegateBridgeCallbackWithToken:)
    func bridgeCallback(token: String) -> AnyObject {
        let block: @convention(block) (AnyObject?) -> AnyObject? = { [weak self] request in
            guard let self, let request, let device = lock.withLock({ self.devices[token] }) else { return Self.emptyResponse() }
            return send(request, to: device)
        }
        return block as AnyObject
    }

    @objc(accessibilityTranslationConvertPlatformFrameToSystem:withToken:)
    func convertFrame(rect: NSRect, withToken token: String) -> NSRect {
        rect
    }

    @objc(accessibilityTranslationRootParentWithToken:)
    func rootParent(withToken token: String) -> AnyObject? {
        nil
    }

    private func send(_ request: AnyObject, to device: NSObject) -> AnyObject? {
        let selector = NSSelectorFromString("sendAccessibilityRequestAsync:completionQueue:completionHandler:")
        guard device.responds(to: selector) else { return Self.emptyResponse() }
        final class Box: @unchecked Sendable { var value: AnyObject? }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        let completion: @convention(block) (AnyObject?) -> Void = { response in
            box.value = response
            done.signal()
        }
        typealias Send = @convention(c) (AnyObject, Selector, AnyObject, DispatchQueue, AnyObject) -> Void
        unsafeBitCast(device.method(for: selector), to: Send.self)(device, selector, request, replies, completion as AnyObject)
        guard done.wait(timeout: .now() + 5) == .success else { return Self.emptyResponse() }
        return box.value ?? Self.emptyResponse()
    }

    private static func emptyResponse() -> AnyObject? {
        (NSClassFromString("AXPTranslatorResponse") as? NSObject.Type)?
            .perform(NSSelectorFromString("emptyResponse"))?.takeUnretainedValue()
    }
}
