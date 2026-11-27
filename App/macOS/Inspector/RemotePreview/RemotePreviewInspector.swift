import AppKit
import SwiftUI
@preconcurrency import WebRTC

/// The Browser or Simulator tab for a chat on another Mac: live video of
/// that Mac's browser or simulator, which the user clicks and types into
/// as the iPhone app's preview does.
struct RemotePreviewInspector: View {
    let item: HostTask
    let source: LivePreviewSource
    @State private var preview: LivePreviewSession
    @State private var address = ""

    init(item: HostTask, source: LivePreviewSource) {
        self.item = item
        self.source = source
        _preview = State(initialValue: LivePreviewSession(
            host: item.host, taskID: item.task.id, source: source, followsHost: true
        ))
    }

    private var host: HostClient { item.host }

    var body: some View {
        let start = preview.startKey
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaBar(edge: .top) {
                bar
                    // As the other tabs place their search bars.
                    .padding(.horizontal, 10)
                    .padding(.top, 9)
                    .padding(.bottom, 8)
            }
            .alert("Control Unavailable", isPresented: Binding(
                get: { preview.inputError != nil }, set: { if !$0 { preview.inputError = nil } }
            )) {
                Button("OK", role: .cancel) { preview.inputError = nil }
            } message: {
                Text(preview.inputError ?? "")
            }
            .task(id: start) {
                guard start != nil else { return preview.stop() }
                await preview.start()
                // Picks up a browser or simulator an agent opens meanwhile.
                while !Task.isCancelled, (try? await Task.sleep(for: .seconds(3))) != nil {
                    await preview.checkForSource()
                }
            }
            .onDisappear(perform: preview.stop)
    }

    @ViewBuilder
    private var content: some View {
        if let error = preview.error {
            ContentUnavailableView {
                Label("\(source.title) Unavailable", systemImage: "exclamationmark.circle")
            } description: {
                Text(error)
            } actions: {
                Button("Try Again", action: preview.restart)
            }
        } else if !host.isConnected {
            ProgressView("Waiting for Mac…")
        } else if preview.isBrowserClosed {
            Color.clear
        } else if source == .simulator, preview.simulatorID == nil, let simulators = preview.simulators {
            ContentUnavailableView {
                Label(simulators.isEmpty ? "No Running Simulators" : "No Simulator", systemImage: "iphone")
            } description: {
                Text(simulators.isEmpty
                     ? "Boot a simulator on \(host.name) to show it here."
                     : "Choose a simulator on \(host.name) to show it beside this chat. Agents show the one they use here too.")
            } actions: {
                if !simulators.isEmpty {
                    simulatorMenu(simulators) { Text("Choose Simulator") }
                        .fixedSize()
                }
            }
        } else {
            ZStack {
                if let track = preview.track, let id = preview.attempt {
                    RemotePreviewVideo(track: track, preview: preview, attempt: id,
                                       cornerRadius: source == .simulator ? 24 : 0)
                        .id(id)
                        .aspectRatio(preview.videoSize ?? CGSize(width: 9, height: 19.5), contentMode: .fit)
                        .padding(source == .simulator ? 12 : 0)
                        .opacity(preview.isPlaying ? 1 : 0)
                }
                if !preview.isPlaying {
                    ProgressView(source == .simulator && preview.simulators == nil ? "Finding Simulators…" : "Connecting…")
                }
            }
        }
    }

    @ViewBuilder
    private var bar: some View {
        switch source {
        case .browser:
            SearchBar(text: $address, placeholder: "Search or enter address", clears: false, onSubmit: {
                let typed = address.trimmingCharacters(in: .whitespacesAndNewlines)
                if !typed.isEmpty { preview.openPage(typed) }
            }) {
                BrowserNavigation(canGoBack: preview.isPlaying, canGoForward: preview.isPlaying) {
                    preview.send(.back)
                } forward: {
                    preview.send(.forward)
                }
            } trailing: {
                BrowserBarButton(title: "Reload", symbol: "arrow.clockwise") { preview.send(.reload) }
                    .disabled(!preview.isPlaying)
            }
            .disabled(!host.isConnected)
        case .simulator:
            HStack(spacing: 6) {
                let current = preview.simulators?.first { $0.id == preview.simulatorID }
                simulatorMenu(preview.simulators ?? []) {
                    SimulatorBarTitle(symbol: current?.symbol, name: current?.name, runtime: current?.runtime)
                }
                .simulatorBarMenu()
                .disabled(preview.simulators?.isEmpty != false)

                Spacer(minLength: 0)

                BrowserBarButton(title: "Home", symbol: "house") { preview.send(.home) }
                    .disabled(!preview.isPlaying)
            }
            .simulatorBarCapsule()
        }
    }

    private func simulatorMenu(_ devices: [LivePreviewSimulator], @ViewBuilder label: () -> some View) -> some View {
        Menu {
            ForEach(devices) { device in
                Toggle(isOn: Binding {
                    preview.simulatorID == device.id
                } set: { _ in
                    preview.chooseSimulator(device.id)
                }) {
                    Label("\(device.name) (\(device.runtime))", systemImage: device.symbol)
                }
            }
        } label: {
            label()
        }
    }
}

/// The video, which takes clicks and drags as taps and swipes and, once
/// clicked, the keyboard's typing.
private struct RemotePreviewVideo: NSViewRepresentable {
    let track: RTCVideoTrack
    let preview: LivePreviewSession
    let attempt: UUID
    let cornerRadius: CGFloat

    func makeNSView(context: Context) -> RemotePreviewVideoView {
        let view = RemotePreviewVideoView()
        view.send = { [weak preview] input in preview?.send(input) }
        view.sizeChanged = { [weak preview] size in preview?.videoChanged(size: size, attempt: attempt) }
        view.track = track
        view.cornerRadius = cornerRadius
        return view
    }

    func updateNSView(_ view: RemotePreviewVideoView, context: Context) {
        view.track = track
        view.cornerRadius = cornerRadius
    }

    static func dismantleNSView(_ view: RemotePreviewVideoView, coordinator: ()) {
        view.track = nil
    }
}
