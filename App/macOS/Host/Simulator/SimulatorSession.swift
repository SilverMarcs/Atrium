import AppKit
import CoreImage
import UniformTypeIdentifiers

/// One simulator as Atrium shows and drives it: its screen, its input, its
/// bezel and which way it's turned. Every chat showing the same simulator
/// shares one session.
@MainActor
@Observable
final class SimulatorSession {
    let udid: String
    private(set) var device: SimulatorDevice
    /// How far the device is turned clockwise, in quarter turns.
    private(set) var quarterTurns = 0
    /// Whether Atrium is booting or shutting it down.
    private(set) var isChangingPower = false
    /// Booted, but iOS is still bringing up its home screen, which takes
    /// a while after CoreSimulator calls it booted and ignores touches meanwhile.
    private(set) var isStarting = false
    @ObservationIgnored private var starting: Task<Void, Never>?
    @ObservationIgnored let screen: SimulatorScreen
    @ObservationIgnored let input: SimulatorInput
    @ObservationIgnored let chrome: SimulatorChrome
    /// CoreSimulator's `SimDevice`, which the screen, input and accessibility reads go through.
    @ObservationIgnored nonisolated(unsafe) let simDevice: NSObject
    @ObservationIgnored private var notificationID: UInt?
    /// The elements the agent's latest snapshot named, by ref, in points.
    @ObservationIgnored var refs: [String: SimulatorAccessibility.Element] = [:]
    /// When an agent last used it, which keeps it open for a while when no chat shows it.
    @ObservationIgnored var lastAgentUse = Date.distantPast

    init?(udid: String) {
        guard let simDevice = SimulatorKit.simDevice(udid: udid), let device = SimulatorDevice(device: simDevice) else { return nil }
        self.udid = udid
        self.device = device
        self.simDevice = simDevice
        screen = SimulatorScreen(device: simDevice)
        input = SimulatorInput(device: simDevice)
        chrome = SimulatorChrome.load(for: simDevice, screen: screen.pointSize)
        watchState()
        if device.state == .booting { followStartUp() }
    }

    isolated deinit {
        unwatchState()
        recording?.interrupt()
        // The next session for this simulator starts upright, so the device does too.
        if quarterTurns != 0 { input.rotate(to: .portrait) }
    }

    var isBooted: Bool { device.state == .booted }

    // MARK: - Power

    func boot() async throws {
        guard device.state == .shutdown else { return }
        isChangingPower = true
        defer { isChangingPower = false }
        try await SimulatorKit.simctl(["boot", udid])
        refreshState()
    }

    func shutDown() async throws {
        guard device.state == .booted else { return }
        isChangingPower = true
        defer { isChangingPower = false }
        try await SimulatorKit.simctl(["shutdown", udid])
        refreshState()
    }

    /// Follows the simulator booting and shutting down, whoever does it.
    private func watchState() {
        let selector = NSSelectorFromString("registerNotificationHandlerOnQueue:handler:")
        guard simDevice.responds(to: selector) else { return }
        let handler: @convention(block) (NSDictionary?) -> Void = { [weak self] info in
            guard info?["notification"] as? String == "device_state" else { return }
            MainActor.assumeIsolated { self?.refreshState() }
        }
        typealias Register = @convention(c) (AnyObject, Selector, AnyObject, AnyObject) -> UInt
        notificationID = unsafeBitCast(simDevice.method(for: selector), to: Register.self)(
            simDevice, selector, DispatchQueue.main, handler as AnyObject)
    }

    private func unwatchState() {
        let selector = NSSelectorFromString("unregisterNotificationHandler:error:")
        guard let notificationID, simDevice.responds(to: selector) else { return }
        typealias Unregister = @convention(c) (AnyObject, Selector, UInt, AutoreleasingUnsafeMutablePointer<NSError?>) -> ObjCBool
        var error: NSError?
        _ = unsafeBitCast(simDevice.method(for: selector), to: Unregister.self)(simDevice, selector, notificationID, &error)
    }

    private func refreshState() {
        guard let updated = SimulatorDevice(device: simDevice) else { return }
        if updated.state != .booted {
            quarterTurns = 0
            if isRecording { Task { await stopRecording() } }
        }
        if updated.state == .booting || (updated.state == .booted && device.state != .booted && !isStarting) {
            followStartUp()
        } else if updated.state != .booted, updated.state != .booting {
            starting?.cancel()
            isStarting = false
        }
        device = updated
    }

    /// Marks the simulator as starting until its screen has drawn the home
    /// screen and gone still: a burst of frames, then a quiet moment.
    private func followStartUp() {
        guard starting == nil else { return }
        isStarting = true
        input.prepare()
        starting = Task { [weak self] in
            let deadline = ContinuousClock.now + .seconds(30)
            while let self, !Task.isCancelled, ContinuousClock.now < deadline {
                if device.state == .booted {
                    screen.watch()
                    if screen.changes >= 30 {
                        await screen.waitUntilStill(quiet: .seconds(2), timeout: .seconds(15))
                        break
                    }
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
            self?.isStarting = false
            self?.starting = nil
        }
    }

    // MARK: - Controls

    /// Turns the device a quarter turn, as Simulator's Rotate Left and Right do.
    func rotate(clockwise: Bool) {
        quarterTurns = (quarterTurns + (clockwise ? 1 : 3)) % 4
        input.rotate(to: orientation)
    }

    private var orientation: SimulatorInput.Orientation {
        switch quarterTurns {
        case 1: .landscapeLeft
        case 2: .upsideDown
        case 3: .landscapeRight
        default: .portrait
        }
    }

    /// The screen's size in points as it's turned now.
    var turnedPointSize: CGSize {
        let size = screen.pointSize
        return quarterTurns % 2 == 0 ? size : CGSize(width: size.height, height: size.width)
    }

    /// A point on the screen as it's turned now, in points, as the simulator's
    /// upright screen takes it: a fraction of its width and height.
    func screenFraction(ofPoint point: CGPoint) -> CGPoint {
        let size = turnedPointSize
        return uprightFraction(ofTurned: CGPoint(x: point.x / size.width, y: point.y / size.height))
    }

    /// Undoes the turn: a fraction of the turned screen to one of the upright screen.
    private func uprightFraction(ofTurned point: CGPoint) -> CGPoint {
        switch quarterTurns {
        case 1: CGPoint(x: point.y, y: 1 - point.x)
        case 2: CGPoint(x: 1 - point.x, y: 1 - point.y)
        case 3: CGPoint(x: 1 - point.y, y: point.x)
        default: point
        }
    }

    /// The upright screen edge that's at the bottom as the device is turned,
    /// where swiping up goes home.
    var bottomEdge: SimulatorInput.Edge {
        switch quarterTurns {
        case 1: .right
        case 2: .top
        case 3: .left
        default: .bottom
        }
    }

    /// Copies the Mac's clipboard text into the simulator's, for pasting there.
    func pasteMacClipboard() async {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        _ = try? await SimulatorKit.simctl(["pbcopy", udid], input: Data(text.utf8))
    }

    /// Light or dark, as the simulator is set.
    func appearance() async -> String? {
        try? await SimulatorKit.simctl(["ui", udid, "appearance"])
    }

    func setAppearance(_ appearance: String) async throws {
        try await SimulatorKit.simctl(["ui", udid, "appearance", appearance])
    }

    func open(url: String) async throws {
        try await SimulatorKit.simctl(["openurl", udid, url])
    }

    // MARK: - Recording

    /// Whether the screen is being recorded to a movie.
    var isRecording: Bool { recording != nil }
    @ObservationIgnored private var recordingFile: URL?
    private var recording: Process?

    /// Records the screen to a movie until `stopRecording`, as `simctl io recordVideo` does.
    func startRecording() throws {
        guard recording == nil, isBooted else { return }
        let file = Self.desktopFile("Simulator Recording", device: device.name, extension: "mov")
        let process = SimulatorKit.simctlProcess(["io", udid, "recordVideo", "--codec=h264", "--force", file.path(percentEncoded: false)])
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, recording === process else { return }
                recording = nil
            }
        }
        try process.run()
        recording = process
        recordingFile = file
    }

    /// Stops recording; the movie is written once `simctl` finishes it.
    @discardableResult
    func stopRecording() async -> URL? {
        guard let process = recording else { return nil }
        recording = nil
        // simctl writes the movie out when it's interrupted, as by Control-C.
        process.interrupt()
        await Task.detached { process.waitUntilExit() }.value
        return recordingFile
    }

    /// A file on the Desktop named as Simulator names its screenshots.
    static func desktopFile(_ kind: String, device: String, extension pathExtension: String) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let desktop = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Desktop")
        return desktop.appending(path: "\(kind) - \(device) - \(formatter.string(from: .now)).\(pathExtension)")
    }

    // MARK: - Screenshots

    /// The screen as it looks now, turned the way the device is, as PNG.
    /// `points` sizes it in points rather than the screen's pixels.
    func screenshot(points: Bool = false) async throws -> Data {
        guard isBooted else { throw SimulatorError("\(device.name) is shut down; boot it first.") }
        guard var image = await screen.image() else { throw SimulatorError("\(device.name) has drawn nothing yet.") }
        if quarterTurns != 0 { image = Self.turned(image, quarterTurns: quarterTurns) ?? image }
        if points, screen.scale > 1 { image = Self.scaled(image, by: 1 / screen.scale) ?? image }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw SimulatorError("Couldn't make the screenshot.")
        }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    private static func turned(_ image: CGImage, quarterTurns: Int) -> CGImage? {
        let swap = quarterTurns % 2 == 1
        let width = swap ? image.height : image.width
        let height = swap ? image.width : image.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        // Core Graphics turns counterclockwise for positive angles, with y up.
        context.translateBy(x: CGFloat(width) / 2, y: CGFloat(height) / 2)
        context.rotate(by: -CGFloat(quarterTurns) * .pi / 2)
        context.draw(image, in: CGRect(x: -CGFloat(image.width) / 2, y: -CGFloat(image.height) / 2,
                                       width: CGFloat(image.width), height: CGFloat(image.height)))
        return context.makeImage()
    }

    private static func scaled(_ image: CGImage, by factor: CGFloat) -> CGImage? {
        let width = Int((CGFloat(image.width) * factor).rounded())
        let height = Int((CGFloat(image.height) * factor).rounded())
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
