import AppKit
import CoreImage
import IOSurface
import WebKit
@preconcurrency import WebRTC

/// The preview follows an existing browser or simulator. It never boots a
/// device or opens a page on its own.
final class PreviewCapture {
    enum Source {
        case browser(AgentBrowser)
        case simulator(SimulatorSession)
    }

    private let source: Source

    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private let video: RTCVideoSource
    private let capturer = RTCVideoCapturer()
    private var pool: CVPixelBufferPool?
    private var dimensions: CGSize = .zero
    private var lastBrowserFrame: CVPixelBuffer?
    private var browserUpdates: Task<Void, Never>?
    private var simulatorViewer: UUID?
    private var nextSimulatorFrame: Task<Void, Never>?
    private var lastSimulatorFrame: ContinuousClock.Instant?
    private var lastSurface: (id: IOSurfaceID, seed: UInt32, turns: Int)?

    init(source: Source, video: RTCVideoSource) {
        self.source = source
        self.video = video
    }

    func start() {
        switch source {
        case .browser(let browser):
            guard browserUpdates == nil else { return }
            browserUpdates = Task { [weak self, weak browser] in
                var delay = Duration.milliseconds(200)
                while let self, let browser, !Task.isCancelled {
                    browser.lastUsed = .now
                    let config = WKSnapshotConfiguration()
                    config.snapshotWidth = NSNumber(value: min(browser.webView.bounds.width, 960))
                    config.afterScreenUpdates = true
                    let snapshot = try? await browser.webView.takeSnapshot(configuration: config)
                    guard !Task.isCancelled else { return }
                    let image = snapshot?.cgImage(forProposedRect: nil, context: nil, hints: nil)
                    let changed = image.map { self.send(CIImage(cgImage: $0), skipDuplicates: true) } ?? false
                    delay = changed ? .milliseconds(200) : min(delay * 2, .seconds(1))
                    try? await Task.sleep(for: delay)
                }
            }
        case .simulator(let session):
            guard simulatorViewer == nil else { return }
            simulatorViewer = session.screen.addViewer { [weak self, weak session] in
                guard let session else { return }
                self?.scheduleSimulatorFrame(session)
            }
        }
    }

    func stop() {
        browserUpdates?.cancel()
        browserUpdates = nil
        lastBrowserFrame = nil
        nextSimulatorFrame?.cancel()
        nextSimulatorFrame = nil
        lastSimulatorFrame = nil
        lastSurface = nil
        if let simulatorViewer, case .simulator(let session) = source {
            session.screen.removeViewer(simulatorViewer)
        }
        simulatorViewer = nil
        pool = nil
    }

    private func scheduleSimulatorFrame(_ session: SimulatorSession) {
        // Coalesce changes and always send the final frame of a burst.
        guard nextSimulatorFrame == nil, let surface = session.screen.surface else { return }
        if let lastSurface, lastSurface == (IOSurfaceGetID(surface), IOSurfaceGetSeed(surface), session.quarterTurns) { return }
        let now = ContinuousClock.now
        let deadline = lastSimulatorFrame.map { $0 + .milliseconds(67) } ?? now
        nextSimulatorFrame = Task { [weak self, weak session] in
            if deadline > now { try? await Task.sleep(until: deadline, clock: .continuous) }
            guard let self, let session, !Task.isCancelled else { return }
            nextSimulatorFrame = nil
            guard let surface = session.screen.surface else { return }
            let current = (IOSurfaceGetID(surface), IOSurfaceGetSeed(surface), session.quarterTurns)
            if let lastSurface, lastSurface == current { return }
            let orientation: CGImagePropertyOrientation = switch session.quarterTurns {
            case 1: .right
            case 2: .down
            case 3: .left
            default: .up
            }
            if send(CIImage(ioSurface: surface).oriented(orientation), skipDuplicates: false) {
                lastSimulatorFrame = .now
                lastSurface = current
            }
        }
    }

    private func send(_ image: CIImage, skipDuplicates: Bool) -> Bool {
        let rect = image.extent
        guard rect.width > 0, rect.height > 0 else { return false }
        let scale = min(1, 960 / max(rect.width, rect.height))
        let width = max(2, Int(rect.width * scale) / 2 * 2)
        let height = max(2, Int(rect.height * scale) / 2 * 2)
        let size = CGSize(width: width, height: height)
        if pool == nil || dimensions != size {
            dimensions = size
            lastBrowserFrame = nil
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            ]
            CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
        }
        guard let pool else { return false }
        var output: CVPixelBuffer?
        let limit = [kCVPixelBufferPoolAllocationThresholdKey as String: 5] as CFDictionary
        guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool, limit, &output) == kCVReturnSuccess,
              let output else { return false }
        let image = image.transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
            .transformed(by: CGAffineTransform(scaleX: CGFloat(width) / rect.width, y: CGFloat(height) / rect.height))
        context.render(image, to: output, bounds: CGRect(origin: .zero, size: size), colorSpace: colorSpace)
        if skipDuplicates {
            if let previous = lastBrowserFrame, Self.matches(output, previous) { return false }
            lastBrowserFrame = output
        }
        let frame = RTCVideoFrame(
            buffer: RTCCVPixelBuffer(pixelBuffer: output), rotation: ._0,
            timeStampNs: Int64(DispatchTime.now().uptimeNanoseconds)
        )
        video.capturer(capturer, didCapture: frame)
        return true
    }

    private static func matches(_ first: CVPixelBuffer, _ second: CVPixelBuffer) -> Bool {
        guard CVPixelBufferLockBaseAddress(first, .readOnly) == kCVReturnSuccess else { return false }
        defer { CVPixelBufferUnlockBaseAddress(first, .readOnly) }
        guard CVPixelBufferLockBaseAddress(second, .readOnly) == kCVReturnSuccess else { return false }
        defer { CVPixelBufferUnlockBaseAddress(second, .readOnly) }
        guard let firstBase = CVPixelBufferGetBaseAddress(first),
              let secondBase = CVPixelBufferGetBaseAddress(second) else { return false }
        let firstStride = CVPixelBufferGetBytesPerRow(first)
        let secondStride = CVPixelBufferGetBytesPerRow(second)
        let rowBytes = CVPixelBufferGetWidth(first) * 4
        return (0..<CVPixelBufferGetHeight(first)).allSatisfy { row in
            memcmp(firstBase + row * firstStride, secondBase + row * secondStride, rowBytes) == 0
        }
    }
}
