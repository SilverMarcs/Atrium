import Foundation
@preconcurrency import WebRTC

/// A video-only peer. SDP carries a batch of ICE candidates over the paired
/// connection. Video travels over the peer connection once it is established.
final class PreviewPeer: NSObject, RTCPeerConnectionDelegate {
    private static let factory = RTCPeerConnectionFactory(
        encoderFactory: RTCDefaultVideoEncoderFactory(),
        decoderFactory: RTCDefaultVideoDecoderFactory()
    )
    private static let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)

    private let connection: RTCPeerConnection
    var onState: ((RTCPeerConnectionState) -> Void)?

    init(iceServers: [PreviewICEServer]) throws {
        let config = RTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        config.iceServers = iceServers.map {
            RTCIceServer(urlStrings: $0.urls, username: $0.username, credential: $0.credential)
        }
        guard let connection = Self.factory.peerConnection(with: config, constraints: Self.constraints, delegate: nil) else {
            throw PreviewError("Couldn’t create the preview connection.")
        }
        self.connection = connection
        super.init()
        connection.delegate = self
    }

    var isConnected: Bool { connection.connectionState == .connected }

    var videoTrack: RTCVideoTrack? {
        connection.transceivers.lazy.compactMap { $0.receiver.track as? RTCVideoTrack }.first
    }

    func addVideo() throws -> RTCVideoSource {
        let source = Self.factory.videoSource(forScreenCast: true)
        let track = Self.factory.videoTrack(with: source, trackId: "preview")
        let transceiver = RTCRtpTransceiverInit()
        transceiver.direction = .sendOnly
        let encoding = RTCRtpEncodingParameters()
        encoding.maxBitrateBps = 1_000_000
        encoding.maxFramerate = 15
        transceiver.sendEncodings = [encoding]
        guard connection.addTransceiver(with: track, init: transceiver) != nil else {
            throw PreviewError("Couldn’t add video to the preview connection.")
        }
        return source
    }

    func localDescription(offer: Bool) async throws -> String {
        let description = if offer {
            try await connection.offer(for: Self.constraints)
        } else {
            try await connection.answer(for: Self.constraints)
        }
        try await connection.setLocalDescription(description)
        let deadline = ContinuousClock.now + .seconds(5)
        while connection.iceGatheringState != .complete, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
            guard connection.connectionState != .closed else { throw CancellationError() }
        }
        try Task.checkCancellation()
        guard let sdp = connection.localDescription?.sdp, sdp.contains("a=candidate:") else {
            throw PreviewError("Couldn’t find a network route for the preview.")
        }
        return sdp
    }

    func setRemote(_ sdp: String, offer: Bool) async throws {
        try await connection.setRemoteDescription(RTCSessionDescription(type: offer ? .offer : .answer, sdp: sdp))
    }

    func close() {
        onState = nil
        connection.close()
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        Task { @MainActor [weak self] in
            guard let self, connection.connectionState == newState else { return }
            onState?(newState)
        }
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    nonisolated func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}

nonisolated struct PreviewError: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }

    init(_ message: String) { self.message = message }
}
