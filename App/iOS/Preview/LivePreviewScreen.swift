import AVFoundation
import SwiftUI
@preconcurrency import WebRTC

struct LivePreviewScreen: View {
    let host: HostClient
    let taskID: String
    let source: LivePreviewSource

    @Environment(\.scenePhase) private var scenePhase
    @State private var simulators: [LivePreviewSimulator]?
    @State private var simulatorID: String?
    @State private var requestedSimulatorID: String?
    @State private var retry = UUID()
    @State private var error: String?
    @State private var attempt: UUID?
    @State private var peer: PreviewPeer?
    @State private var track: RTCVideoTrack?
    @State private var connected = false
    @State private var videoSize: CGSize?
    @State private var timeout: Task<Void, Never>?
    @State private var inputTask: Task<Void, Never>?
    @State private var inputError: String?
    @State private var showingAddress = false
    @State private var address = ""
    @State private var showingKeyboard = false
    @State private var text = ""
    @FocusState private var keyboardFocused: Bool

    private struct Start: Equatable {
        let retry: UUID
        let route: HostClient.Route?
    }

    private var canConnect: Bool { scenePhase == .active && host.isConnected }

    private var startRequest: Start? {
        guard canConnect else { return nil }
        return Start(retry: retry, route: host.route)
    }

    private var isPlaying: Bool { connected && videoSize != nil }

    var body: some View {
        let request = startRequest
        Group {
            if let error {
                ContentUnavailableView {
                    Label("\(source.title) Unavailable", systemImage: "exclamationmark.circle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try Again", action: retryPreview)
                }
            } else if source == .simulator, simulatorID == nil, let simulators {
                simulatorPicker(simulators)
            } else if !host.isConnected {
                ProgressView("Waiting for Mac…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                video
            }
        }
        .navigationTitle(source.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if source == .browser {
                    Menu("Browser Controls", systemImage: "ellipsis.circle") {
                        Button("Open Page", systemImage: "globe") {
                            address = ""
                            showingAddress = true
                        }
                        Button("Back", systemImage: "chevron.left") { send(.back) }
                        Button("Forward", systemImage: "chevron.right") { send(.forward) }
                        Button("Reload", systemImage: "arrow.clockwise") { send(.reload) }
                    }
                    .disabled(!isPlaying)
                } else if let simulators, !simulators.isEmpty {
                    Button("Home", systemImage: "house") { send(.home) }
                        .disabled(!isPlaying)
                    if simulators.count > 1, simulatorID != nil {
                        Menu("Choose Simulator", systemImage: "iphone.sizes") {
                            Picker("Simulator", selection: Binding(
                                get: { simulatorID },
                                set: { if let id = $0 { chooseSimulator(id) } }
                            )) {
                                ForEach(simulators) { device in
                                    Label(device.name, systemImage: device.symbol).tag(Optional(device.id))
                                }
                            }
                        }
                    }
                }
                Button("Keyboard", systemImage: "keyboard") {
                    showingKeyboard.toggle()
                    keyboardFocused = showingKeyboard
                }
                .disabled(!isPlaying)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if showingKeyboard { keyboardBar }
        }
        .alert("Open Page", isPresented: $showingAddress) {
            TextField("Address or search", text: $address)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Open") { send(.openPage(address)) }
                .disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) {}
        }
        .alert("Control Unavailable", isPresented: Binding(
            get: { inputError != nil }, set: { if !$0 { inputError = nil } }
        )) {
            Button("OK", role: .cancel) { inputError = nil }
        } message: {
            Text(inputError ?? "")
        }
        .task(id: request) {
            guard !Task.isCancelled else { return }
            stop()
            if request != nil { await startPreview() }
        }
        .onDisappear(perform: stop)
    }

    private var video: some View {
        GeometryReader { geometry in
            ZStack {
                if let track, let id = attempt {
                    PreviewVideoView(track: track) { size in
                        guard attempt == id else { return }
                        videoSize = size
                        finishSetupIfPlaying()
                    }
                    .id(id)
                    .background(.black)
                    .opacity(isPlaying ? 1 : 0)
                }
                if let videoSize, isPlaying {
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0).onEnded { gesture in
                            let rect = AVMakeRect(
                                aspectRatio: videoSize, insideRect: CGRect(origin: .zero, size: geometry.size)
                            )
                            guard rect.width > 0, rect.height > 0, rect.contains(gesture.startLocation) else { return }
                            let start = previewPoint(gesture.startLocation, in: rect)
                            let end = previewPoint(gesture.location, in: rect)
                            let movement = hypot(gesture.translation.width, gesture.translation.height)
                            send(movement < 8 ? .tap(start) : .swipe(from: start, to: end))
                        })
                } else {
                    ProgressView(source == .simulator && simulators == nil ? "Finding Simulators…" : "Connecting…")
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }

    private var keyboardBar: some View {
        HStack {
            TextField("Type on \(source.title)", text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
                .focused($keyboardFocused)
                .submitLabel(.send)
                .onSubmit(sendText)
            Button("Send Text", systemImage: "arrow.up.circle.fill", action: sendText)
                .disabled(text.isEmpty)
            Button("Backspace", systemImage: "delete.left") { send(.key(.backspace)) }
            Button("Return", systemImage: "return") { send(.key(.enter)) }
        }
        .labelStyle(.iconOnly)
        .padding()
        .background(.bar)
        .disabled(!isPlaying)
    }

    private func simulatorPicker(_ devices: [LivePreviewSimulator]) -> some View {
        Group {
            if devices.isEmpty {
                ContentUnavailableView {
                    Label("No Running Simulators", systemImage: "iphone.slash")
                } description: {
                    Text("Boot a simulator on the Mac to use it here.")
                } actions: {
                    Button("Refresh", action: retryPreview)
                }
            } else {
                List(devices) { device in
                    Button {
                        chooseSimulator(device.id)
                    } label: {
                        Label {
                            VStack(alignment: .leading) {
                                Text(device.name)
                                Text(device.runtime).font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: device.symbol)
                        }
                    }
                }
            }
        }
    }

    private func previewPoint(_ point: CGPoint, in rect: CGRect) -> PreviewPoint {
        PreviewPoint(
            x: min(1, max(0, (point.x - rect.minX) / rect.width)),
            y: min(1, max(0, (point.y - rect.minY) / rect.height))
        )
    }

    private func retryPreview() {
        retry = UUID()
    }

    private func chooseSimulator(_ id: String) {
        guard id != simulatorID else { return }
        requestedSimulatorID = id
        retryPreview()
    }

    private func startPreview() async {
        error = nil
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
        await start(simulatorID: requestedSimulatorID)
    }

    private func sendText() {
        guard isPlaying, !text.isEmpty else { return }
        guard text.utf8.count <= LivePreviewInput.maxTextBytes else {
            inputError = "Send up to 4 KB of text at a time."
            return
        }
        send(.text(text))
        text = ""
    }

    private func send(_ input: LivePreviewInput) {
        guard isPlaying, canConnect, let id = attempt else { return }
        let previous = inputTask
        inputTask = Task {
            await previous?.value
            guard !Task.isCancelled, attempt == id, isPlaying, canConnect else { return }
            do {
                _ = try await host.request(.preview(.input(id: id, input)))
            } catch {
                if !Task.isCancelled, attempt == id { inputError = error.localizedDescription }
            }
        }
    }

    private func start(simulatorID: String?) async {
        guard !Task.isCancelled else { return }
        error = nil
        let id = UUID()
        attempt = id
        setTimeout(id, after: .seconds(25))
        do {
            guard case .previewOffer(let offer, let iceServers) = try await host.request(
                .preview(.start(id: id, taskID: taskID, source: source, openBrowser: source == .browser, simulatorID: simulatorID))
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
            Task { _ = try? await host.request(.preview(.stop(id: id))) }
        }
    }
}

private struct PreviewVideoView: UIViewRepresentable {
    let track: RTCVideoTrack
    let videoReady: (CGSize) -> Void

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
        private let videoReady: (CGSize) -> Void

        init(videoReady: @escaping (CGSize) -> Void) {
            self.videoReady = videoReady
        }

        nonisolated func videoView(_ videoView: any RTCVideoRenderer, didChangeVideoSize size: CGSize) {
            guard size.width > 0, size.height > 0 else { return }
            Task { @MainActor [weak self] in self?.videoReady(size) }
        }
    }
}
