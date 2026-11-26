import Foundation
import Observation
@preconcurrency import WebRTC

/// One companion connection owns one preview, including any pending setup.
final class HostLivePreview {
    let id: UUID
    private var peer: PreviewPeer?
    private var capture: PreviewCapture?
    private var deadline: Task<Void, Never>?
    private var input: Task<Void, any Error>?
    private var stopped = false
    private var answered = false
    private var isAvailable: (() -> Bool)?

    init(id: UUID) {
        self.id = id
    }

    isolated deinit { stop() }

    func offer(
        for target: PreviewCapture.Source, useRelay: Bool, isAvailable: @escaping () -> Bool
    ) async throws -> HostReply {
        let iceServers: [PreviewICEServer]
        if !useRelay {
            iceServers = []
        } else if let key = CloudflareTURN.key {
            // STUN still lets direct connections work if the TURN API is temporarily unavailable.
            iceServers = (try? await key.iceServers()) ?? [.stun]
        } else {
            iceServers = [.stun]
        }
        guard !stopped, isAvailable() else { throw PreviewError("This preview has ended.") }
        let peer = try PreviewPeer(iceServers: iceServers)
        self.peer = peer
        capture = PreviewCapture(source: target, video: try peer.addVideo())
        self.isAvailable = isAvailable
        watchSource()
        peer.onState = { [weak self] state in self?.update(state) }
        stopAfter(.seconds(25))
        let offer = try await peer.localDescription(offer: true)
        guard !stopped else { throw CancellationError() }
        return .previewOffer(sdp: offer, iceServers: iceServers)
    }

    func answer(_ sdp: String) async throws {
        guard !answered, let peer else { throw PreviewError("This preview has ended.") }
        answered = true
        try await peer.setRemote(sdp, offer: false)
    }

    func control(_ action: LivePreviewInput) async throws {
        guard let capture, peer?.isConnected == true, isAvailable?() == true else {
            throw PreviewError("This preview isn’t connected.")
        }
        guard input == nil else { throw PreviewError("The Mac is still handling the previous input.") }
        let task = Task { try await capture.source.perform(action) }
        input = task
        defer {
            input = nil
            capture.refreshAfterInput()
        }
        try await task.value
    }

    func stop() {
        stopped = true
        isAvailable = nil
        deadline?.cancel()
        deadline = nil
        input?.cancel()
        capture?.stop()
        capture = nil
        peer?.close()
        peer = nil
    }

    private func watchSource() {
        guard let isAvailable else { return }
        let available = withObservationTracking(isAvailable) { [weak self] in
            Task { @MainActor [weak self] in self?.watchSource() }
        }
        if !available { stop() }
    }

    private func update(_ state: RTCPeerConnectionState) {
        switch state {
        case .connected:
            deadline?.cancel()
            deadline = nil
            capture?.start()
        case .disconnected:
            input?.cancel()
            capture?.stop()
            stopAfter(.seconds(8))
        case .failed, .closed:
            stop()
        default:
            break
        }
    }

    private func stopAfter(_ duration: Duration) {
        deadline?.cancel()
        deadline = Task { [weak self] in
            guard (try? await Task.sleep(for: duration)) != nil else { return }
            self?.stop()
        }
    }
}
