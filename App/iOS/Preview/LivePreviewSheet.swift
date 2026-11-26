import SwiftUI
@preconcurrency import WebRTC

struct LivePreviewSheet: View {
    let host: HostClient
    let taskID: String

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var sources: [LivePreviewSource]?
    @State private var selection: LivePreviewSource?
    @State private var loadError: String?
    @State private var error: String?
    @State private var retry = UUID()
    @State private var attempt: UUID?
    @State private var peer: PreviewPeer?
    @State private var track: RTCVideoTrack?
    @State private var connected = false
    @State private var hasVideo = false
    @State private var timeout: Task<Void, Never>?

    private struct Start: Equatable {
        let source: LivePreviewSource
        let retry: UUID
        let route: HostClient.Route?
    }

    private var startRequest: Start? {
        guard scenePhase == .active, host.isConnected, let selection else { return nil }
        return Start(source: selection, retry: retry, route: host.route)
    }

    private var isPlaying: Bool { connected && hasVideo }

    var body: some View {
        let request = startRequest
        NavigationStack {
            Group {
                if let sources, sources.isEmpty {
                    ContentUnavailableView {
                        Label("No Live Preview", systemImage: "rectangle.slash")
                    } description: {
                        Text("Open a browser or simulator in this task on the Mac.")
                    } actions: {
                        Button("Refresh") { Task { await loadSources() } }
                    }
                } else if let message = loadError ?? error {
                    ContentUnavailableView {
                        Label("Preview Unavailable", systemImage: "exclamationmark.circle")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("Try Again") { Task { await loadSources() } }
                    }
                } else {
                    ZStack {
                        if let track, let id = attempt {
                            PreviewVideoView(track: track) {
                                guard attempt == id else { return }
                                hasVideo = true
                                finishSetupIfPlaying()
                            }
                            .id(id)
                            .background(.black)
                            .opacity(isPlaying ? 1 : 0)
                        }
                        if !isPlaying {
                            ProgressView(sources == nil ? "Finding Previews…" : "Connecting…")
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .top, spacing: 0) {
                if let sources, sources.count > 1 {
                    Picker("Source", selection: $selection) {
                        ForEach(sources) { source in
                            Label(source.title, systemImage: source.symbol).tag(Optional(source))
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding()
                    .background(.bar)
                }
            }
            .navigationTitle("Live Preview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task { await loadSources() }
        .task(id: request) {
            guard !Task.isCancelled else { return }
            stop()
            if let request { await start(request.source) }
        }
        .onDisappear(perform: stop)
    }

    private func loadSources() async {
        loadError = nil
        do {
            guard case .previewSources(let sources) = try await host.request(.preview(.sources(taskID: taskID))) else {
                throw PreviewError("Update Diffs on the Mac to use live previews.")
            }
            guard !Task.isCancelled else { return }
            self.sources = sources
            if let selection, sources.contains(selection) {
                retry = UUID()
            } else {
                selection = sources.first
            }
        } catch {
            if !Task.isCancelled { loadError = error.localizedDescription }
        }
    }

    private func start(_ source: LivePreviewSource) async {
        guard !Task.isCancelled else { return }
        error = nil
        let id = UUID()
        attempt = id
        setTimeout(id, after: .seconds(25))
        do {
            guard case .previewOffer(let offer, let iceServers) = try await host.request(
                .preview(.start(id: id, taskID: taskID, source: source))
            ) else { throw PreviewError("The Mac didn’t start a preview.") }
            guard attempt == id, !Task.isCancelled else { return }
            let peer = try PreviewPeer(iceServers: iceServers)
            self.peer = peer
            peer.onState = { state in
                guard attempt == id else { return }
                switch state {
                case .connected:
                    connected = true
                    finishSetupIfPlaying()
                case .disconnected:
                    connected = false
                    setTimeout(id, after: .seconds(8))
                case .failed, .closed:
                    fail("The Mac and companion couldn’t connect for live video.")
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
        timeout = Task {
            guard (try? await Task.sleep(for: duration)) != nil, attempt == id else { return }
            fail(connected ? "No video arrived from the Mac." : "The live preview connection timed out.")
        }
    }

    private func finishSetupIfPlaying() {
        guard isPlaying else { return }
        timeout?.cancel()
        timeout = nil
    }

    private func fail(_ message: String) {
        stop()
        error = message
    }

    private func stop() {
        let id = attempt
        attempt = nil
        timeout?.cancel()
        timeout = nil
        peer?.close()
        peer = nil
        track = nil
        connected = false
        hasVideo = false
        if let id {
            Task { _ = try? await host.request(.preview(.stop(id: id))) }
        }
    }
}

private struct PreviewVideoView: UIViewRepresentable {
    let track: RTCVideoTrack
    let videoReady: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(videoReady: videoReady) }

    func makeUIView(context: Context) -> RTCMTLVideoView {
        let view = RTCMTLVideoView()
        view.videoContentMode = .scaleAspectFit
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ view: RTCMTLVideoView, context: Context) {
        guard context.coordinator.track !== track else { return }
        context.coordinator.track?.remove(view)
        context.coordinator.track = track
        track.add(view)
    }

    static func dismantleUIView(_ view: RTCMTLVideoView, coordinator: Coordinator) {
        coordinator.track?.remove(view)
    }

    final class Coordinator: NSObject, RTCVideoViewDelegate {
        var track: RTCVideoTrack?
        private let videoReady: () -> Void

        init(videoReady: @escaping () -> Void) {
            self.videoReady = videoReady
        }

        nonisolated func videoView(_ videoView: any RTCVideoRenderer, didChangeVideoSize size: CGSize) {
            guard size.width > 0, size.height > 0 else { return }
            Task { @MainActor [weak self] in self?.videoReady() }
        }
    }
}
