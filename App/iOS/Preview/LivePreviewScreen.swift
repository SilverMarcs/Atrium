import AVFoundation
import SwiftUI
@preconcurrency import WebRTC

struct LivePreviewScreen: View {
    let host: HostClient
    let taskID: String
    let source: LivePreviewSource

    @Environment(\.scenePhase) private var scenePhase
    @State private var preview: LivePreviewSession
    @State private var showingAddress = false
    @State private var address = ""
    @State private var showingKeyboard = false
    @State private var text = ""
    @FocusState private var keyboardFocused: Bool

    init(host: HostClient, taskID: String, source: LivePreviewSource) {
        self.host = host
        self.taskID = taskID
        self.source = source
        _preview = State(initialValue: LivePreviewSession(host: host, taskID: taskID, source: source))
    }

    var body: some View {
        let start = scenePhase == .active ? preview.startKey : nil
        Group {
            if let error = preview.error {
                ContentUnavailableView {
                    Label("\(source.title) Unavailable", systemImage: "exclamationmark.circle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try Again", action: preview.restart)
                }
            } else if source == .simulator, preview.simulatorID == nil, let simulators = preview.simulators {
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
                        Button("Back", systemImage: "chevron.left") { preview.send(.back) }
                        Button("Forward", systemImage: "chevron.right") { preview.send(.forward) }
                        Button("Reload", systemImage: "arrow.clockwise") { preview.send(.reload) }
                    }
                    .disabled(!preview.isPlaying)
                } else if let simulators = preview.simulators, !simulators.isEmpty {
                    Button("Home", systemImage: "house") { preview.send(.home) }
                        .disabled(!preview.isPlaying)
                    if simulators.count > 1, preview.simulatorID != nil {
                        Menu("Choose Simulator", systemImage: "iphone.sizes") {
                            Picker("Simulator", selection: Binding(
                                get: { preview.simulatorID },
                                set: { if let id = $0 { preview.chooseSimulator(id) } }
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
                .disabled(!preview.isPlaying)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if showingKeyboard { keyboardBar }
        }
        .alert("Open Page", isPresented: $showingAddress) {
            TextField("Address or search", text: $address)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Open") { preview.send(.openPage(address)) }
                .disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) {}
        }
        .alert("Control Unavailable", isPresented: Binding(
            get: { preview.inputError != nil }, set: { if !$0 { preview.inputError = nil } }
        )) {
            Button("OK", role: .cancel) { preview.inputError = nil }
        } message: {
            Text(preview.inputError ?? "")
        }
        .task(id: start) {
            if start == nil { preview.stop() } else { await preview.start() }
        }
        .onDisappear(perform: preview.stop)
    }

    private var video: some View {
        GeometryReader { geometry in
            ZStack {
                if let track = preview.track, let id = preview.attempt {
                    PreviewVideoView(track: track) { size in
                        preview.videoChanged(size: size, attempt: id)
                    }
                    .id(id)
                    .background(.black)
                    .opacity(preview.isPlaying ? 1 : 0)
                }
                if let videoSize = preview.videoSize, preview.isPlaying {
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0).onEnded { gesture in
                            let rect = AVMakeRect(
                                aspectRatio: videoSize, insideRect: CGRect(origin: .zero, size: geometry.size)
                            )
                            if let input = LivePreviewInput.drag(from: gesture.startLocation, to: gesture.location, in: rect) {
                                preview.send(input)
                            }
                        })
                } else {
                    ProgressView(source == .simulator && preview.simulators == nil ? "Finding Simulators…" : "Connecting…")
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
            Button("Backspace", systemImage: "delete.left") { preview.send(.key(.backspace)) }
            Button("Return", systemImage: "return") { preview.send(.key(.enter)) }
        }
        .labelStyle(.iconOnly)
        .padding()
        .background(.bar)
        .disabled(!preview.isPlaying)
    }

    private func simulatorPicker(_ devices: [LivePreviewSimulator]) -> some View {
        Group {
            if devices.isEmpty {
                ContentUnavailableView {
                    Label("No Running Simulators", systemImage: "iphone.slash")
                } description: {
                    Text("Boot a simulator on the Mac to use it here.")
                } actions: {
                    Button("Refresh", action: preview.restart)
                }
            } else {
                List(devices) { device in
                    Button {
                        preview.chooseSimulator(device.id)
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

    private func sendText() {
        guard preview.isPlaying, !text.isEmpty else { return }
        guard text.utf8.count <= LivePreviewInput.maxTextBytes else {
            preview.inputError = "Send up to 4 KB of text at a time."
            return
        }
        preview.send(.text(text))
        text = ""
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
