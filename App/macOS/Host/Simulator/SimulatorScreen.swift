import AppKit
import CoreImage
import IOSurface

/// One booted simulator's screen, read straight from the framebuffer
/// SimulatorKit shares with the simulator: nothing is copied or encoded, so
/// a view can show the surface itself as a layer's contents. The simulator
/// calls back each time it draws, and each viewer redraws then.
///
/// Framebuffer discovery and selection follow serve-sim's FrameCapture
/// (https://github.com/EvanBacon/serve-sim, Apache-2.0), without its encoders.
@MainActor
final class SimulatorScreen {
    /// The surface the screen draws into, once it has one.
    private(set) var surface: IOSurface?
    /// The screen's size in pixels, which the device type gives before any frame.
    let nativeSize: CGSize
    /// Points per pixel row, such as 3 on most iPhones.
    let scale: CGFloat

    private let device: NSObject
    private var descriptors: [NSObject] = []
    private var callbackIDs: [ObjectIdentifier: UUID] = [:]
    private var viewers: [UUID: () -> Void] = [:]
    private var settle: Task<Void, Never>?
    /// When the simulator last drew.
    private var lastFrame = ContinuousClock.now
    private var lastSeed: UInt32 = 0
    /// How many times the picture has changed while followed.
    private(set) var changes = 0
    /// Wires the framebuffer again while no frame has come, which happens
    /// right after boot, when the display ports appear late.
    private var rewire: Task<Void, Never>?
    /// Stops reading the screen a while after a screenshot, when nothing shows it.
    private var idleStop: Task<Void, Never>?

    init(device: NSObject) {
        self.device = device
        let type = device.value(forKey: "deviceType") as? NSObject
        nativeSize = Self.mainScreenSize(of: type) ?? CGSize(width: 1170, height: 2532)
        scale = (type?.value(forKey: "mainScreenScale") as? NSNumber).map { CGFloat($0.floatValue) } ?? 3
    }

    isolated deinit {
        stop()
        idleStop?.cancel()
    }

    /// The screen's size in points, upright.
    var pointSize: CGSize { CGSize(width: nativeSize.width / scale, height: nativeSize.height / scale) }

    var isRunning: Bool { !descriptors.isEmpty }

    /// Calls `onFrame` on the main thread each time the screen changes, until
    /// `removeViewer` with the returned ID.
    func addViewer(_ onFrame: @escaping () -> Void) -> UUID {
        let id = UUID()
        viewers[id] = onFrame
        idleStop?.cancel()
        start()
        if surface != nil { onFrame() }
        return id
    }

    func removeViewer(_ id: UUID) {
        viewers[id] = nil
        if viewers.isEmpty { stop() }
    }

    /// The screen as it is now, upright as the simulator draws it, waiting a
    /// moment for a first frame when nothing was showing it.
    func image() async -> CGImage? {
        let wasRunning = isRunning
        start()
        for _ in 0..<20 where surface == nil {
            try? await Task.sleep(for: .milliseconds(50))
            resolveSurface()
        }
        if !wasRunning, viewers.isEmpty { stopWhenIdle() }
        guard let surface else { return nil }
        let image = CIImage(ioSurface: unsafeBitCast(surface, to: IOSurfaceRef.self))
        return CIContext(options: [.cacheIntermediates: false]).createCGImage(image, from: image.extent)
    }

    /// Starts following the screen ahead of an action, so `waitUntilStill`
    /// sees every frame it sets off.
    func watch() {
        guard !isRunning else { return }
        start()
        lastFrame = .now
        if viewers.isEmpty { stopWhenIdle() }
    }

    /// Waits until the simulator stops drawing for a moment, as it does
    /// once an animation, a keyboard or a load ends, or until `timeout`.
    func waitUntilStill(quiet: Duration = .milliseconds(220), timeout: Duration = .seconds(4)) async {
        let wasRunning = isRunning
        start()
        // Frames only count once they're being watched, so the wait starts now.
        if !wasRunning { lastFrame = .now }
        let deadline = ContinuousClock.now + timeout
        // iOS takes a moment to start what a touch sets off, such as a push.
        try? await Task.sleep(for: max(quiet, .milliseconds(350)))
        while ContinuousClock.now < deadline, ContinuousClock.now - lastFrame < quiet {
            try? await Task.sleep(for: .milliseconds(50))
        }
        if !wasRunning, viewers.isEmpty { stopWhenIdle() }
    }

    // MARK: - Framebuffer

    private func start() {
        guard descriptors.isEmpty else { return }
        wire()
        rewire?.cancel()
        rewire = Task { [weak self] in
            for _ in 0..<10 {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled, isRunning else { return }
                if surface != nil { return }
                wire()
            }
        }
    }

    private func stop() {
        rewire?.cancel()
        rewire = nil
        unregister()
        descriptors = []
        surface = nil
        settle?.cancel()
    }

    private func stopWhenIdle() {
        idleStop?.cancel()
        idleStop = Task { [weak self] in
            guard (try? await Task.sleep(for: .seconds(30))) != nil, let self, viewers.isEmpty else { return }
            stop()
        }
    }

    /// Registers for frames on every display port. Registering is what makes
    /// SimulatorKit connect a port's surface, so before it there's none to read.
    private func wire() {
        unregister()
        guard let io = device.perform(NSSelectorFromString("io"))?.takeUnretainedValue() as? NSObject else { return }
        io.perform(NSSelectorFromString("updateIOPorts"))
        let ports = io.value(forKey: "deviceIOPorts") as? [NSObject] ?? []
        descriptors = ports.compactMap { port in
            guard port.responds(to: NSSelectorFromString("portIdentifier")),
                  let identifier = port.perform(NSSelectorFromString("portIdentifier"))?.takeUnretainedValue(),
                  "\(identifier)" == "com.apple.framebuffer.display",
                  let descriptor = port.perform(NSSelectorFromString("descriptor"))?.takeUnretainedValue() as? NSObject,
                  descriptor.responds(to: NSSelectorFromString("framebufferSurface"))
            else { return nil }
            return descriptor
        }
        for descriptor in descriptors {
            let id = UUID()
            callbackIDs[ObjectIdentifier(descriptor)] = id
            let frame: @convention(block) () -> Void = { [weak self] in
                MainActor.assumeIsolated { self?.frameArrived() }
            }
            let surfacesChanged: @convention(block) () -> Void = { [weak self] in
                MainActor.assumeIsolated {
                    self?.resolveSurface()
                    self?.frameArrived()
                }
            }
            let propertiesChanged: @convention(block) () -> Void = {}
            (descriptor as AnyObject).registerScreenCallbacks(
                uuid: id, callbackQueue: .main, frameCallback: frame,
                surfacesChangedCallback: surfacesChanged, propertiesChangedCallback: propertiesChanged
            )
        }
        resolveSurface()
        frameArrived()
    }

    private func unregister() {
        let selector = NSSelectorFromString("unregisterScreenCallbacksWithUUID:")
        for descriptor in descriptors {
            if let id = callbackIDs[ObjectIdentifier(descriptor)], descriptor.responds(to: selector) {
                descriptor.perform(selector, with: id)
            }
        }
        callbackIDs = [:]
    }

    /// Picks the port drawing the device's own screen: Xcode 27 can also
    /// show a much larger presentation surface while Device Hub resizes, so
    /// the device type's native size wins over the largest.
    private func resolveSurface() {
        let surfaces = descriptors.compactMap { descriptor -> IOSurface? in
            guard let object = descriptor.perform(NSSelectorFromString("framebufferSurface"))?.takeUnretainedValue() else { return nil }
            return unsafeBitCast(object, to: IOSurface.self)
        }
        let native = surfaces.first { surface in
            let size = CGSize(width: IOSurfaceGetWidth(surface), height: IOSurfaceGetHeight(surface))
            return size == nativeSize || size == CGSize(width: nativeSize.height, height: nativeSize.width)
        }
        surface = native ?? surfaces.max { IOSurfaceGetWidth($0) * IOSurfaceGetHeight($0) < IOSurfaceGetWidth($1) * IOSurfaceGetHeight($1) }
    }

    private func frameArrived() {
        if surface == nil { resolveSurface() }
        guard let surface else { return }
        // The simulator calls back for frames that change nothing too.
        let seed = IOSurfaceGetSeed(surface)
        if seed != lastSeed {
            lastSeed = seed
            lastFrame = .now
            changes += 1
        }
        for onFrame in viewers.values { onFrame() }
        // A frame can be announced before its pixels land, and the last one
        // of a change has no frame after it, so each change redraws once more.
        settle?.cancel()
        settle = Task { [weak self] in
            guard (try? await Task.sleep(for: .milliseconds(80))) != nil, let self else { return }
            for onFrame in viewers.values { onFrame() }
        }
    }

    /// `SimDeviceType.mainScreenSize`: the screen's pixels, returned as a
    /// struct, so it's called through its implementation.
    private static func mainScreenSize(of type: NSObject?) -> CGSize? {
        let selector = NSSelectorFromString("mainScreenSize")
        guard let type, type.responds(to: selector) else { return nil }
        typealias GetSize = @convention(c) (AnyObject, Selector) -> CGSize
        let size = unsafeBitCast(type.method(for: selector), to: GetSize.self)(type, selector)
        guard size.width > 0, size.height > 0, size.width.isFinite, size.height.isFinite else { return nil }
        return CGSize(width: size.width.rounded(), height: size.height.rounded())
    }
}

/// SimulatorKit's framebuffer descriptor, for the callback registration
/// that takes blocks.
@objc private protocol FramebufferDescriptor {
    @objc(registerScreenCallbacksWithUUID:callbackQueue:frameCallback:surfacesChangedCallback:propertiesChangedCallback:)
    func registerScreenCallbacks(
        uuid: UUID,
        callbackQueue: DispatchQueue,
        frameCallback: @convention(block) @escaping () -> Void,
        surfacesChangedCallback: @convention(block) @escaping () -> Void,
        propertiesChangedCallback: @convention(block) @escaping () -> Void
    )
}
