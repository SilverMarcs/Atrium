import Foundation
import Observation
@preconcurrency import WebRTC

/// A companion's live view of a task's browser or simulator on its Mac: asks
/// the host for an offer, answers it and follows the video, and sends the
/// user's input back. The iPhone screen and the Mac inspector both show one.
@Observable
final class LivePreviewSession {
    let host: HostClient
    let taskID: String
    let source: LivePreviewSource

    /// The Mac's running simulators, once listed.
    private(set) var simulators: [LivePreviewSimulator]?
    private(set) var simulatorID: String?
    private(set) var error: String?
    /// The task has no browser on the Mac, and this preview doesn't open one.
    private(set) var isBrowserClosed = false
    private var retry = UUID()
    private(set) var attempt: UUID?
    private(set) var track: RTCVideoTrack?
    private(set) var videoSize: CGSize?
    var inputError: String?

    private var connected = false
    @ObservationIgnored private var requestedSimulatorID: String?
    /// A page to open with the next start, then once its video plays.
    @ObservationIgnored private var pendingPage: String?
    @ObservationIgnored private var pageToOpen: String?
    @ObservationIgnored private let followsHost: Bool
    @ObservationIgnored private var peer: PreviewPeer?
    @ObservationIgnored private var timeout: Task<Void, Never>?
    @ObservationIgnored private var inputTask: Task<Void, Never>?

    /// A preview that `followsHost`, as the Mac's inspector tabs do, shows
    /// only what the Mac has: it leaves a closed browser closed until a page
    /// is opened, and when its browser or simulator goes away it looks again
    /// instead of failing. Otherwise, as on iPhone, showing the browser
    /// opens it.
    init(host: HostClient, taskID: String, source: LivePreviewSource, followsHost: Bool = false) {
        self.host = host
        self.taskID = taskID
        self.source = source
        self.followsHost = followsHost
    }

    var isPlaying: Bool { connected && videoSize != nil }

    struct StartKey: Equatable {
        let retry: UUID
        let route: HostClient.Route?
    }

    /// Changes whenever the preview should start again, and is nil while the
    /// host is offline. Views run `start()` for each key and `stop()` for nil.
    var startKey: StartKey? {
        host.isConnected ? StartKey(retry: retry, route: host.route) : nil
    }

    /// Starts the preview again, also after an error.
    func restart() {
        retry = UUID()
    }

    /// Opens a page in the task's browser, opening the browser first when
    /// the Mac has none.
    func openPage(_ address: String) {
        guard !isPlaying else { return send(.openPage(address)) }
        pendingPage = address
        restart()
    }

    /// While there's nothing to show, looks again for the browser or
    /// simulator an agent may have opened since, and shows it.
    func checkForSource() async {
        guard error == nil, attempt == nil else { return }
        if source == .browser, isBrowserClosed {
            guard case .previewSources(let sources)? = try? await host.request(.preview(.sources(taskID: taskID))),
                  isBrowserClosed, sources.contains(.browser) else { return }
            restart()
        } else if source == .simulator, simulatorID == nil, simulators != nil {
            guard case .previewSimulators(let devices, let selectedID)? = try? await host.request(
                .preview(.simulators(taskID: taskID))
            ), simulatorID == nil, attempt == nil else { return }
            simulators = devices
            if selectedID.map({ id in devices.contains(where: { $0.id == id }) }) == true { restart() }
        }
    }

    func chooseSimulator(_ id: String) {
        guard id != simulatorID else { return }
        requestedSimulatorID = id
        restart()
    }

    /// Asks the Mac for the preview, for each `startKey`.
    func start() async {
        stop()
        error = nil
        isBrowserClosed = false
        let page = pendingPage
        pendingPage = nil
        if source == .browser, followsHost, page == nil {
            // Showing the preview leaves a closed browser closed, as the Mac's own tab does.
            do {
                guard case .previewSources(let sources) = try await host.request(.preview(.sources(taskID: taskID))) else {
                    throw PreviewError("The Mac didn’t say whether the browser is open.")
                }
                guard !Task.isCancelled else { return }
                guard sources.contains(.browser) else {
                    isBrowserClosed = true
                    return
                }
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
                return
            }
        }
        let requestedSimulatorID = requestedSimulatorID
        self.requestedSimulatorID = nil
        if source == .simulator {
            if let requestedSimulatorID {
                simulatorID = requestedSimulatorID
            } else {
                // Reconnecting follows the current Mac attachment. Only a
                // choice made in the picker can change it.
                simulatorID = nil
                simulators = nil
                do {
                    guard case .previewSimulators(let devices, let selectedID) = try await host.request(
                        .preview(.simulators(taskID: taskID))
                    ) else { throw PreviewError("Update Diffs on the Mac to use simulator controls.") }
                    guard !Task.isCancelled else { return }
                    simulators = devices
                    simulatorID = selectedID.flatMap { id in devices.contains(where: { $0.id == id }) ? id : nil }
                    guard simulatorID != nil else { return }
                } catch {
                    if !Task.isCancelled { self.error = error.localizedDescription }
                    return
                }
            }
        }
        pageToOpen = page
        await connect(simulatorID: requestedSimulatorID, openBrowser: !followsHost || page != nil)
    }

    func send(_ input: LivePreviewInput) {
        guard isPlaying, let id = attempt else { return }
        let previous = inputTask
        inputTask = Task {
            await previous?.value
            guard !Task.isCancelled, attempt == id, isPlaying else { return }
            do {
                _ = try await host.request(.preview(.input(id: id, input)))
            } catch {
                if !Task.isCancelled, attempt == id { inputError = error.localizedDescription }
            }
        }
    }

    /// The video view saw the first frame of `attempt`, or a new size.
    func videoChanged(size: CGSize, attempt id: UUID) {
        guard attempt == id else { return }
        videoSize = size
        finishSetupIfPlaying()
    }

    func stop() {
        let id = attempt
        attempt = nil
        pageToOpen = nil
        inputTask?.cancel()
        inputTask = nil
        timeout?.cancel()
        timeout = nil
        peer?.close()
        peer = nil
        track = nil
        connected = false
        videoSize = nil
        if let id {
            Task { [host] in _ = try? await host.request(.preview(.stop(id: id))) }
        }
    }

    private func connect(simulatorID: String?, openBrowser: Bool) async {
        guard !Task.isCancelled else { return }
        error = nil
        let id = UUID()
        attempt = id
        setTimeout(id, after: .seconds(25))
        do {
            let request = LivePreviewRequest.start(
                id: id, taskID: taskID, source: source,
                openBrowser: source == .browser && openBrowser, simulatorID: simulatorID
            )
            guard case .previewOffer(let offer, let iceServers) = try await host.request(.preview(request)) else {
                throw PreviewError("The Mac didn’t start a preview.")
            }
            guard attempt == id, !Task.isCancelled else { return }
            let peer = try PreviewPeer(iceServers: iceServers)
            self.peer = peer
            peer.onState = { [weak self] state in
                guard let self, attempt == id else { return }
                switch state {
                case .connected:
                    connected = true
                    finishSetupIfPlaying()
                case .disconnected:
                    connected = false
                    setTimeout(id, after: .seconds(8))
                case .failed, .closed:
                    fail("The Mac and this device couldn’t connect for live video.")
                default:
                    break
                }
            }
            try await peer.setRemote(offer, offer: true)
            guard attempt == id, !Task.isCancelled else { return }
            guard let video = peer.videoTrack else { throw PreviewError("The Mac didn’t offer a video track.") }
            track = video
            let answer = try await peer.localDescription(offer: false)
            guard attempt == id, !Task.isCancelled else { return }
            _ = try await host.request(.preview(.answer(id: id, sdp: answer)))
        } catch {
            if attempt == id, !Task.isCancelled { fail(error.localizedDescription) }
        }
    }

    private func setTimeout(_ id: UUID, after duration: Duration) {
        timeout?.cancel()
        timeout = Task { [weak self] in
            guard (try? await Task.sleep(for: duration)) != nil, let self, attempt == id else { return }
            fail(connected ? "No video arrived from the Mac." : "The live preview connection timed out.")
        }
    }

    private func finishSetupIfPlaying() {
        guard isPlaying else { return }
        timeout?.cancel()
        timeout = nil
        if let pageToOpen {
            self.pageToOpen = nil
            send(.openPage(pageToOpen))
        }
    }

    private func fail(_ message: String) {
        // A preview that played lost its source or its connection; starting
        // again finds out which, and shows what the Mac has now.
        let played = videoSize != nil
        stop()
        if followsHost, played {
            restart()
        } else {
            error = message
        }
    }
}
