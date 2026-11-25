import CoreGraphics
import Darwin
import Foundation
@preconcurrency import XPC

/// Touches, keys and hardware buttons for one simulator, in the order they're
/// sent. Points are fractions of the screen as the simulator draws it, upright
/// (0,0 top left, 1,1 bottom right), whichever way the device is turned.
///
/// Xcode 27 simulators take input through `dtuhidd`, the CoreDevice HID
/// service inside the simulator, reached over XPC; while it runs, iOS ignores
/// the older Indigo keyboard. Simulators without it (Xcode 26) get Indigo
/// messages through SimulatorKit's legacy HID client, as serve-sim
/// (https://github.com/EvanBacon/serve-sim, Apache-2.0) sends them.
nonisolated final class SimulatorInput: @unchecked Sendable {
    enum Phase: UInt64 { case began = 0, moved = 1, ended = 2 }

    /// Which screen edge a touch starts at, for system gestures such as
    /// swiping up from the bottom to go home.
    enum Edge: UInt64 { case none = 0, left = 1, top = 2, bottom = 3, right = 4 }

    /// Hardware buttons as HID usages on the consumer page.
    enum Button {
        case home, lock, siri, volumeUp, volumeDown
        case usage(page: UInt32, usage: UInt32)

        /// The named buttons, as agents name them.
        static let named: [String: Button] = ["home": .home, "lock": .lock, "siri": .siri, "volume_up": .volumeUp, "volume_down": .volumeDown]

        var usage: (page: UInt32, usage: UInt32) {
            switch self {
            case .home: (0x0C, 0x40)
            case .lock: (0x0C, 0x30)
            case .siri: (0x0C, 0xCF)
            case .volumeUp: (0x0C, 0xE9)
            case .volumeDown: (0x0C, 0xEA)
            case .usage(let page, let usage): (page, usage)
            }
        }
    }

    /// The device's rotation as GraphicsServices names it.
    enum Orientation: UInt32 { case portrait = 1, upsideDown = 2, landscapeRight = 3, landscapeLeft = 4 }

    private let device: NSObject
    private let queue = DispatchQueue(label: "Atrium.SimulatorInput", qos: .userInteractive)
    private var transport: Transport?
    /// A new `dtuhidd` session adds its keyboard to the simulator, which
    /// takes keys only once iOS has picked it up.
    private var keysReadyAt = Date.distantPast
    /// How far behind their times events go out while keys wait for a new
    /// session, so a press and its release stay as far apart as they were.
    private var lag: TimeInterval = 0

    /// `device` is the simulator's `SimDevice`.
    init(device: NSObject) {
        self.device = device
    }

    deinit {
        transport?.close()
    }

    /// Connects ahead of the first touch or key, so keys typed soon after work.
    func prepare() {
        queue.async { _ = self.connected() }
    }

    func touch(_ phase: Phase, at point: CGPoint, second: CGPoint? = nil, edge: Edge = .none) {
        let point = Self.clamped(point)
        let second = second.map(Self.clamped)
        send(at: Date(), needsKeys: false) { $0.touch(phase, point, second, edge) }
    }

    func key(_ usage: UInt32, down: Bool) {
        send(at: Date(), needsKeys: true) { $0.key(usage, down: down) }
    }

    func press(_ button: Button, down: Bool) {
        send(at: Date(), needsKeys: true) { $0.button(button.usage.page, button.usage.usage, down: down) }
    }

    /// A press held for `hold` seconds, a tap on the button by default.
    func press(_ button: Button, hold: TimeInterval = 0.1) {
        let now = Date()
        send(at: now, needsKeys: true) { $0.button(button.usage.page, button.usage.usage, down: true) }
        send(at: now.addingTimeInterval(hold), needsKeys: true) { $0.button(button.usage.page, button.usage.usage, down: false) }
    }

    /// Sends an event at its time, in order with the others. Keys and buttons
    /// on a session that's just started wait until it takes them, and what
    /// follows waits as long, keeping the gaps between events.
    private func send(at time: Date, needsKeys: Bool, _ event: @escaping (Transport) -> Void) {
        queue.async {
            guard let transport = self.connected() else { return }
            var due = time.addingTimeInterval(self.lag)
            if time >= self.keysReadyAt {
                self.lag = 0
                due = time
            } else if needsKeys, due < self.keysReadyAt {
                self.lag += self.keysReadyAt.timeIntervalSince(due)
                due = self.keysReadyAt
            }
            let wait = due.timeIntervalSinceNow
            if wait > 0 { Thread.sleep(forTimeInterval: wait) }
            event(transport)
        }
    }

    /// Turns the device, which the simulator answers by drawing its screen turned.
    func rotate(to orientation: Orientation) {
        queue.async {
            guard let port = Self.lookUp("PurpleWorkspacePort", on: self.device) else { return }
            Self.sendOrientation(orientation.rawValue, to: port)
        }
    }

    /// Waits for everything sent so far to be handed over.
    func flush() async {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume() }
        }
    }

    // MARK: - Transport

    private func connected() -> Transport? {
        if let transport, transport.isOpen { return transport }
        transport?.close()
        transport = nil
        guard (device.value(forKey: "state") as? NSNumber)?.intValue == SimulatorDevice.State.booted.rawValue else { return nil }
        if let dtuhid = DTUHIDTransport(device: device) {
            transport = dtuhid
            keysReadyAt = Date().addingTimeInterval(1)
        } else {
            transport = IndigoTransport(device: device)
            keysReadyAt = .distantPast
        }
        return transport
    }

    private static func clamped(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(point.x, 0), 1), y: min(max(point.y, 0), 1))
    }

    /// `-[SimDevice lookup:error:]`: a Mach service inside the simulator.
    static func lookUp(_ service: String, on device: NSObject) -> mach_port_t? {
        let selector = NSSelectorFromString("lookup:error:")
        guard device.responds(to: selector) else { return nil }
        typealias Lookup = @convention(c) (AnyObject, Selector, NSString, AutoreleasingUnsafeMutablePointer<NSError?>) -> mach_port_t
        var error: NSError?
        let port = unsafeBitCast(device.method(for: selector), to: Lookup.self)(device, selector, service as NSString, &error)
        return port == 0 ? nil : port
    }

    /// A GraphicsServices orientation event to the simulator's workspace
    /// port, as Simulator.app turns the device (after idb and serve-sim).
    private static func sendOrientation(_ orientation: UInt32, to port: mach_port_t) {
        var buffer = [UInt8](repeating: 0, count: 112)
        buffer.withUnsafeMutableBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            let header = base.assumingMemoryBound(to: mach_msg_header_t.self)
            header.pointee.msgh_bits = mach_msg_bits_t(MACH_MSG_TYPE_COPY_SEND)
            header.pointee.msgh_size = 108
            header.pointee.msgh_remote_port = port
            header.pointee.msgh_local_port = mach_port_t(MACH_PORT_NULL)
            header.pointee.msgh_id = 0x7B
            // Device orientation changed, from the host; then the payload size and the orientation.
            base.storeBytes(of: UInt32(50) | 0x20000, toByteOffset: 0x18, as: UInt32.self)
            base.storeBytes(of: UInt32(4), toByteOffset: 0x48, as: UInt32.self)
            base.storeBytes(of: orientation, toByteOffset: 0x4C, as: UInt32.self)
            _ = mach_msg_send(header)
        }
    }
}

private nonisolated protocol Transport: AnyObject {
    var isOpen: Bool { get }
    func touch(_ phase: SimulatorInput.Phase, _ point: CGPoint, _ second: CGPoint?, _ edge: SimulatorInput.Edge)
    func key(_ usage: UInt32, down: Bool)
    func button(_ page: UInt32, _ usage: UInt32, down: Bool)
    func close()
}

// MARK: - dtuhidd

/// Plain XPC dictionaries to the simulator's `dtuhidd`: each names its
/// message type and carries a payload of numbers. The connection comes from
/// the service's Mach port through libxpc's simulator endpoint functions.
private nonisolated final class DTUHIDTransport: Transport, @unchecked Sendable {
    static let service = "com.apple.coredevice.feature.remote.hid.digitizer"

    private let connection: xpc_connection_t
    private let lock = NSLock()
    private var open = true

    var isOpen: Bool { lock.withLock { open } }

    init?(device: NSObject) {
        typealias EndpointFromPort = @convention(c) (mach_port_t, UInt64, UInt64) -> xpc_object_t?
        typealias ConnectionFromEndpoint = @convention(c) (xpc_object_t) -> xpc_connection_t?
        typealias EnableSimToHost = @convention(c) (xpc_connection_t) -> Void
        guard let handle = dlopen(nil, RTLD_NOW),
              let endpointSymbol = dlsym(handle, "xpc_endpoint_create_mach_port_4sim"),
              let connectionSymbol = dlsym(handle, "xpc_connection_create_from_endpoint"),
              let simToHostSymbol = dlsym(handle, "xpc_connection_enable_sim2host_4sim"),
              let port = SimulatorInput.lookUp(Self.service, on: device),
              let endpoint = unsafeBitCast(endpointSymbol, to: EndpointFromPort.self)(port, 0, 0),
              let connection = unsafeBitCast(connectionSymbol, to: ConnectionFromEndpoint.self)(endpoint)
        else { return nil }
        unsafeBitCast(simToHostSymbol, to: EnableSimToHost.self)(connection)
        self.connection = connection
        xpc_connection_set_event_handler(connection) { [weak self] event in
            guard xpc_get_type(event) == XPC_TYPE_ERROR, let self else { return }
            lock.withLock { self.open = false }
        }
        xpc_connection_resume(connection)
        // dtuhidd starts on the first connection after a boot, which takes a
        // couple of seconds; events sent before it answers are lost.
        let answered = DispatchSemaphore(value: 0)
        let barrier = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_bool(barrier, "isBarrier", true)
        xpc_connection_send_message_with_reply(connection, barrier, .global()) { _ in answered.signal() }
        _ = answered.wait(timeout: .now() + 5)
    }

    deinit { xpc_connection_cancel(connection) }

    func close() {
        lock.withLock { open = false }
        // Lets what was just sent reach the simulator before the session ends.
        let connection = connection
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) { xpc_connection_cancel(connection) }
    }

    func touch(_ phase: SimulatorInput.Phase, _ point: CGPoint, _ second: CGPoint?, _ edge: SimulatorInput.Edge) {
        send("IndigoDigitizerEvent") { payload in
            xpc_dictionary_set_value(payload, "pointOne", Self.point(point))
            if let second { xpc_dictionary_set_value(payload, "pointTwo", Self.point(second)) }
            xpc_dictionary_set_uint64(payload, "eventType", phase.rawValue)
            xpc_dictionary_set_uint64(payload, "edge", edge.rawValue)
            xpc_dictionary_set_uint64(payload, "target", 0)
        }
    }

    func key(_ usage: UInt32, down: Bool) {
        send("IndigoKeyboardButtonEvent") { payload in
            xpc_dictionary_set_uint64(payload, "usageCode", UInt64(usage))
            xpc_dictionary_set_uint64(payload, "state", down ? 1 : 2)
        }
    }

    func button(_ page: UInt32, _ usage: UInt32, down: Bool) {
        send("IndigoButtonEvent") { payload in
            xpc_dictionary_set_uint64(payload, "usagePage", UInt64(page))
            xpc_dictionary_set_uint64(payload, "usageCode", UInt64(usage))
            xpc_dictionary_set_uint64(payload, "state", down ? 1 : 2)
        }
    }

    private func send(_ type: String, payload fill: (xpc_object_t) -> Void) {
        let message = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(message, "messageType", type)
        xpc_dictionary_set_bool(message, "isBarrier", false)
        xpc_dictionary_set_string(message, "featureIdentifier", Self.service)
        let payload = xpc_dictionary_create(nil, nil, 0)
        fill(payload)
        xpc_dictionary_set_value(message, "payload", payload)
        xpc_connection_send_message(connection, message)
    }

    private static func point(_ point: CGPoint) -> xpc_object_t {
        let object = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_double(object, "x", Double(point.x))
        xpc_dictionary_set_double(object, "y", Double(point.y))
        return object
    }
}

// MARK: - Indigo

/// SimulatorKit's legacy HID client, for simulators without `dtuhidd`.
private nonisolated final class IndigoTransport: Transport {
    private typealias MouseMessage = @convention(c) (
        UnsafePointer<CGPoint>, UnsafePointer<CGPoint>?, UInt32, Int32, CGFloat, CGFloat, UInt32
    ) -> UnsafeMutableRawPointer?
    private typealias KeyboardMessage = @convention(c) (UInt32, UInt32) -> UnsafeMutableRawPointer?
    private typealias ArbitraryMessage = @convention(c) (UInt32, UInt32, UInt32, UInt32) -> UnsafeMutableRawPointer?
    private typealias Send = @convention(c) (AnyObject, Selector, UnsafeMutableRawPointer, ObjCBool, AnyObject?, AnyObject?) -> Void

    private let client: NSObject
    private let mouse: MouseMessage
    private let keyboard: KeyboardMessage?
    private let arbitrary: ArbitraryMessage?
    private let sendSelector = NSSelectorFromString("sendWithMessage:freeWhenDone:completionQueue:completion:")
    private var open = true

    var isOpen: Bool { open }

    init?(device: NSObject) {
        let symbols = UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT
        guard let mouseSymbol = dlsym(symbols, "IndigoHIDMessageForMouseNSEvent"),
              let clientClass = NSClassFromString("_TtC12SimulatorKit24SimDeviceLegacyHIDClient") else { return nil }
        let initSelector = NSSelectorFromString("initWithDevice:error:")
        typealias Initialize = @convention(c) (AnyObject, Selector, AnyObject, AutoreleasingUnsafeMutablePointer<NSError?>) -> AnyObject?
        guard let implementation = class_getMethodImplementation(clientClass, initSelector),
              let allocated = (clientClass as? NSObject.Type)?.perform(NSSelectorFromString("alloc"))?.takeUnretainedValue() else { return nil }
        var error: NSError?
        guard let client = unsafeBitCast(implementation, to: Initialize.self)(allocated, initSelector, device, &error) as? NSObject else { return nil }
        self.client = client
        mouse = unsafeBitCast(mouseSymbol, to: MouseMessage.self)
        keyboard = dlsym(symbols, "IndigoHIDMessageForKeyboardArbitrary").map { unsafeBitCast($0, to: KeyboardMessage.self) }
        arbitrary = dlsym(symbols, "IndigoHIDMessageForHIDArbitrary").map { unsafeBitCast($0, to: ArbitraryMessage.self) }
    }

    func close() { open = false }

    func touch(_ phase: SimulatorInput.Phase, _ point: CGPoint, _ second: CGPoint?, _ edge: SimulatorInput.Edge) {
        // Moves are downs at the new place; the function takes no drag type.
        let type: Int32 = phase == .ended ? 2 : 1
        var first = point
        let message: UnsafeMutableRawPointer?
        if var second {
            message = mouse(&first, &second, 0x32, type, 1, 1, 0)
        } else {
            message = mouse(&first, nil, 0x32, type, 1, 1, UInt32(edge.rawValue))
        }
        message.map(send)
    }

    func key(_ usage: UInt32, down: Bool) {
        keyboard?(usage, down ? 1 : 2).map(send)
    }

    func button(_ page: UInt32, _ usage: UInt32, down: Bool) {
        arbitrary?(0x32, page, usage, down ? 1 : 2).map(send)
    }

    private func send(_ message: UnsafeMutableRawPointer) {
        guard let implementation = class_getMethodImplementation(object_getClass(client), sendSelector) else {
            free(message)
            return
        }
        unsafeBitCast(implementation, to: Send.self)(client, sendSelector, message, true, nil, nil)
    }
}
