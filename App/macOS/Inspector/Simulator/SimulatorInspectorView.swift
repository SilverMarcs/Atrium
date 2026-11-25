import SwiftUI

/// The inspector's Simulator tab: the simulator the chat shows, live in its
/// bezel, which the user can use like Simulator and the chat's agent opens
/// with `simulator_open`. A bar above picks the simulator and holds its
/// controls.
struct SimulatorInspectorView: View {
    let item: HostTask?
    @Environment(AppModel.self) private var app
    @AppStorage("simulator.showsBezel") private var showsBezel = true
    @State private var problem: SimulatorProblem?

    /// Only chats on this Mac show a simulator.
    private var taskID: String? { item.flatMap { $0.host.isLocal ? $0.task.id : nil } }
    private var simulators: AgentSimulators { app.simulators }
    private var session: SimulatorSession? { taskID.flatMap(simulators.session(for:)) }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaBar(edge: .top) {
                SimulatorBar(session: session, taskID: taskID, showsBezel: $showsBezel, report: report)
                    .disabled(taskID == nil)
                    // As the other tabs place their search bars.
                    .padding(.horizontal, 10)
                    .padding(.top, 9)
                    .padding(.bottom, 8)
            }
            .alert(problem?.title ?? "", isPresented: Binding { problem != nil } set: { if !$0 { problem = nil } }) {
                Button("OK") { problem = nil }
            } message: {
                Text(problem?.message ?? "")
            }
            // Keeps the picker's list and the simulator's state current while the tab shows.
            .task {
                while !Task.isCancelled {
                    await simulators.refreshDevices()
                    try? await Task.sleep(for: .seconds(3))
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if !simulators.isAvailable {
            ContentUnavailableView("Simulators Need Xcode", systemImage: "xmark.octagon",
                                   description: Text("Install Xcode to show and use simulators here."))
        } else if let session {
            SimulatorScreenArea(session: session, showsBezel: showsBezel, report: report)
        } else {
            ContentUnavailableView {
                Label("No Simulator", systemImage: "iphone")
            } description: {
                Text("Choose a simulator to show it beside this chat. Agents show the one they use here too.")
            } actions: {
                if let taskID {
                    SimulatorPicker(taskID: taskID, current: nil) {
                        Text("Choose Simulator")
                    }
                    .fixedSize()
                }
            }
        }
    }

    private func report(_ title: String, _ error: any Error) {
        problem = SimulatorProblem(title: title, message: error.localizedDescription)
    }
}

/// Something the user asked of the simulator that failed, for the tab's alert.
private struct SimulatorProblem {
    let title: String
    let message: String
}

/// Shows that something failed, with a title such as "Couldn't Boot".
private typealias ReportProblem = (_ title: String, _ error: any Error) -> Void

/// The simulator itself, or what's keeping it from showing.
private struct SimulatorScreenArea: View {
    let session: SimulatorSession
    let showsBezel: Bool
    let report: ReportProblem

    var body: some View {
        // The device takes only the room its shape needs, so the bar sits just below it.
        VStack(spacing: 4) {
            screen
                .aspectRatio(displaySize, contentMode: .fit)
            SimulatorActionBar(session: session, report: report)
                .disabled(!session.isBooted)
        }
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The device as drawn, turned as it is, with the margin the display view leaves around it.
    private var displaySize: CGSize {
        let drawing = showsBezel ? session.chrome.size : session.chrome.screen.size
        let turned = session.quarterTurns % 2 == 0 ? drawing : CGSize(width: drawing.height, height: drawing.width)
        let margin = SimulatorDisplayView.margin * 2
        return CGSize(width: turned.width + margin, height: turned.height + margin)
    }

    private var screen: some View {
        ZStack {
            SimulatorDisplay(session: session, showsBezel: showsBezel)
                .opacity(session.isBooted ? 1 : 0.35)
                .overlay(alignment: .bottom) {
                    if session.isBooted, session.isStarting {
                        Label {
                            Text("iOS is starting…")
                        } icon: {
                            ProgressView().controlSize(.mini)
                        }
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .glassEffect(.regular, in: Capsule())
                        .padding(.bottom, 28)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                    }
                }
                .animation(.easeOut(duration: 0.2), value: session.isStarting)
            if !session.isBooted {
                ContentUnavailableView {
                    Label(session.device.name, systemImage: session.device.family.symbol)
                } description: {
                    Text(session.device.state == .booting || session.isChangingPower
                         ? "Starting…" : "\(session.device.runtime) · \(session.device.state.title)")
                } actions: {
                    if session.device.state == .shutdown {
                        Button("Boot") {
                            Task {
                                do { try await session.boot() } catch { report("Couldn't Boot", error) }
                            }
                        }
                        .disabled(session.isChangingPower)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
            }
        }
    }
}

/// The device's own controls in a bar below it, as Device Hub shows them:
/// Home, the side button, rotation, a screenshot and a screen recording.
private struct SimulatorActionBar: View {
    let session: SimulatorSession
    let report: ReportProblem

    var body: some View {
        HStack(spacing: 2) {
            control("Home (⇧⌘H)", "house") { session.input.press(.home) }
            control("Side Button", "lock") { session.input.press(.lock) }
            control("Rotate (⌘→)", "rotate.right") { session.rotate(clockwise: true) }
            control("Save Screenshot to Desktop", "camera") { saveScreenshot() }
            control(session.isRecording ? "Stop Recording and Save to Desktop" : "Record Screen",
                    session.isRecording ? "stop.circle.fill" : "record.circle", tint: session.isRecording ? .red : nil) {
                toggleRecording()
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .glassEffect(.regular, in: Capsule())
        .animation(.easeOut(duration: 0.2), value: session.isRecording)
    }

    private func control(_ title: String, _ symbol: String, tint: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .foregroundStyle(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.primary))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 32, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
    }

    private func saveScreenshot() {
        Task {
            do {
                let png = try await session.screenshot()
                try png.write(to: SimulatorSession.desktopFile("Simulator Screenshot", device: session.device.name, extension: "png"))
            } catch {
                report("Couldn't Save the Screenshot", error)
            }
        }
    }

    private func toggleRecording() {
        guard !session.isRecording else {
            Task { await session.stopRecording() }
            return
        }
        do { try session.startRecording() } catch { report("Couldn't Record", error) }
    }
}

/// Hosts the AppKit view that shows and drives the simulator.
private struct SimulatorDisplay: NSViewRepresentable {
    let session: SimulatorSession
    let showsBezel: Bool

    func makeNSView(context: Context) -> SimulatorDisplayView {
        SimulatorDisplayView()
    }

    func updateNSView(_ view: SimulatorDisplayView, context: Context) {
        view.session = session
        view.showsBezel = showsBezel
        view.isBooted = session.isBooted
        view.quarterTurns = session.quarterTurns
    }
}

/// The bar over the simulator: which one, what the agent's doing with it,
/// and its controls.
private struct SimulatorBar: View {
    let session: SimulatorSession?
    let taskID: String?
    @Binding var showsBezel: Bool
    let report: ReportProblem
    @Environment(AppModel.self) private var app
    @State private var appearance: String?
    @State private var askingForURL = false
    @State private var url = ""

    private var booted: Bool { session?.isBooted == true }

    var body: some View {
        HStack(spacing: 6) {
            if let taskID {
                SimulatorPicker(taskID: taskID, current: session?.device) {
                    HStack(spacing: 5) {
                        Image(systemName: session?.device.family.symbol ?? "iphone")
                            .foregroundStyle(.secondary)
                        Text(session?.device.name ?? "Choose Simulator")
                            .lineLimit(1)
                        if let runtime = session?.device.runtime {
                            Text(runtime)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .font(.subheadline)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.visible)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(-1)
            } else {
                Text("Simulator")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            if let taskID, app.simulators.agentUsing.contains(taskID) {
                AgentUsingBadge(help: "The agent is using the simulator")
            }

            Menu {
                moreMenu
            } label: {
                BrowserBarSymbol(symbol: "ellipsis")
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .frame(height: 12)
            .help("More")
            .disabled(session == nil)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .frame(minHeight: 26)
        .background(.quaternary, in: Capsule())
        .animation(.easeOut(duration: 0.2), value: taskID.map { app.simulators.agentUsing.contains($0) })
        .task(id: session?.udid) {
            appearance = booted ? await session?.appearance() : nil
        }
        .alert("Open URL", isPresented: $askingForURL) {
            TextField("https://… or myapp://", text: $url)
            Button("Open") { run("Couldn't Open the URL") { try await session?.open(url: url) } }
            Button("Cancel", role: .cancel) {}
        }
    }

    @ViewBuilder
    private var moreMenu: some View {
        Group {
            Picker("Appearance", selection: Binding {
                appearance ?? "light"
            } set: { value in
                appearance = value
                run("Couldn't Change the Appearance") { try await session?.setAppearance(value) }
            }) {
                Label("Light", systemImage: "sun.max").tag("light")
                Label("Dark", systemImage: "moon").tag("dark")
            }
            .pickerStyle(.inline)

            Button("Rotate Left", systemImage: "rotate.left") { session?.rotate(clockwise: false) }
            Button("Rotate Right", systemImage: "rotate.right") { session?.rotate(clockwise: true) }
            Button("Open URL…", systemImage: "link") { askingForURL = true }
            Button("Paste Mac Clipboard", systemImage: "doc.on.clipboard") {
                Task { await session?.pasteMacClipboard() }
            }

            Section("Buttons") {
                Button("Siri", systemImage: "waveform") { session?.input.press(.siri) }
                Button("Volume Up", systemImage: "speaker.plus") { session?.input.press(.volumeUp) }
                Button("Volume Down", systemImage: "speaker.minus") { session?.input.press(.volumeDown) }
            }
        }
        .disabled(!booted)

        Section {
            Toggle("Show Bezel", systemImage: "iphone", isOn: $showsBezel)
            if let session {
                if session.isBooted {
                    Button("Shut Down", systemImage: "power") { run("Couldn't Shut Down") { try await session.shutDown() } }
                } else if session.device.state == .shutdown {
                    Button("Boot", systemImage: "power") { run("Couldn't Boot") { try await session.boot() } }
                }
            }
            if let taskID {
                Button("Remove from Chat", systemImage: "xmark") { app.simulators.close(taskID) }
            }
        }
    }

    private func run(_ title: String, _ work: @escaping () async throws -> Void) {
        Task {
            do { try await work() } catch { report(title, error) }
        }
    }
}

/// A menu of Xcode's simulators, booted first, that shows the chosen one in the chat.
private struct SimulatorPicker<Title: View>: View {
    let taskID: String
    let current: SimulatorDevice?
    @ViewBuilder let label: Title
    @Environment(AppModel.self) private var app

    var body: some View {
        let devices = app.simulators.devices
        let booted = devices.filter { $0.state == .booted }
        let others = devices.filter { $0.state != .booted }
        Menu {
            if devices.isEmpty {
                Text("No Simulators")
            }
            if !booted.isEmpty {
                Section("Booted") { rows(booted) }
            }
            ForEach(Self.groups(others), id: \.runtime) { group in
                Section(group.runtime) { rows(group.devices) }
            }
        } label: {
            label
        }
    }

    private func rows(_ devices: [SimulatorDevice]) -> some View {
        ForEach(devices) { device in
            Toggle(isOn: Binding {
                current?.udid == device.udid
            } set: { _ in
                app.simulators.show(device.udid, in: taskID)
            }) {
                Label {
                    Text(device.state == .booted ? "\(device.name) (\(device.runtime))" : device.name)
                } icon: {
                    Image(systemName: device.family.symbol)
                }
            }
        }
    }

    private static func groups(_ devices: [SimulatorDevice]) -> [(runtime: String, devices: [SimulatorDevice])] {
        var order: [String] = []
        var byRuntime: [String: [SimulatorDevice]] = [:]
        for device in devices {
            if byRuntime[device.runtime] == nil { order.append(device.runtime) }
            byRuntime[device.runtime, default: []].append(device)
        }
        // In the list's order, iPhones' runtimes first.
        return order.map { ($0, byRuntime[$0] ?? []) }
    }
}
