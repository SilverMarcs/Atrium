import SwiftUI

struct CompanionRootView: View {
    @Environment(CompanionClient.self) private var client

    var body: some View {
        NavigationStack {
            Group {
                switch client.state {
                case .idle, .browsing, .connecting, .authenticating, .failed:
                    PairingScreen()
                case .connected:
                    SessionsScreen()
                }
            }
            .navigationTitle("Atrium")
            .navigationBarTitleDisplayMode(.inline)
        }
        .task {
            client.startBrowsing()
        }
    }
}

// MARK: - Pairing

private struct PairingScreen: View {
    @Environment(CompanionClient.self) private var client
    @State private var pairingCode: String = ""
    @State private var selectedHost: CompanionClient.DiscoveredHost?

    var body: some View {
        Form {
            Section {
                if client.hosts.isEmpty {
                    HStack {
                        ProgressView()
                        Text("Searching for Atrium on this network…")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(client.hosts) { host in
                        Button {
                            selectedHost = host
                        } label: {
                            HStack {
                                Image(systemName: "macbook")
                                    .foregroundStyle(.secondary)
                                Text(host.name)
                                    .foregroundStyle(.primary)
                                Spacer()
                                if effectiveHost?.id == host.id {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                }
                            }
                            .contentShape(.rect)
                        }
                    }
                }
            } header: {
                Text("Discovered hosts")
            } footer: {
                Text("The Mac running Atrium must be on the same Wi-Fi.")
            }

            Section {
                TextField("123456", text: $pairingCode)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .font(.title2.monospaced())
                Button("Connect") {
                    if let host = effectiveHost {
                        client.connect(to: host, pairingCode: pairingCode)
                    }
                }
                .disabled(effectiveHost == nil || pairingCode.count != 6)
            } header: {
                Text("Pairing code")
            } footer: {
                Text("Open Atrium → Settings → Companion on your Mac to see the 6-digit code.")
            }

            if let saved = savedCode, !saved.isEmpty, pairingCode.isEmpty {
                Section {
                    Button("Use saved code (\(saved))") {
                        pairingCode = saved
                    }
                }
            }

            switch client.state {
            case .connecting(let name):
                Section { Text("Connecting to \(name)…").foregroundStyle(.secondary) }
            case .authenticating:
                Section { Text("Pairing…").foregroundStyle(.secondary) }
            case .failed(let message):
                Section { Text(message).foregroundStyle(.red) }
            default:
                EmptyView()
            }
        }
    }

    private var savedCode: String? { client.savedPairingCode }

    /// If the user explicitly tapped a host, use that. Otherwise — when there
    /// is exactly one host on the network — auto-select it so the Connect
    /// button enables purely from typing the code.
    private var effectiveHost: CompanionClient.DiscoveredHost? {
        if let selectedHost { return selectedHost }
        return client.hosts.count == 1 ? client.hosts.first : nil
    }
}

// MARK: - Sessions list / detail

private struct SessionsScreen: View {
    @Environment(CompanionClient.self) private var client

    var body: some View {
        List {
            ForEach(client.workspaces) { workspace in
                Section(workspace.name) {
                    if workspace.sessions.isEmpty {
                        Text("No sessions").foregroundStyle(.secondary)
                    }
                    ForEach(workspace.sessions.filter { !$0.isArchived }) { session in
                        NavigationLink(value: session.id) {
                            SessionRow(session: session)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { client.requestSessionsList() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Disconnect") { client.disconnect() }
            }
        }
        .navigationDestination(for: UUID.self) { sessionId in
            SessionDetailScreen(sessionId: sessionId)
        }
    }
}

private struct SessionRow: View {
    let session: WireSessionMeta

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(session.title.isEmpty ? "New Chat" : session.title)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Text(session.providerName)
                    Text("•")
                    Text("\(session.turnCount) turns")
                    Text("•")
                    Text(session.date, style: .relative)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if session.isProcessing {
                ProgressView().controlSize(.small)
            }
        }
    }
}

private struct SessionDetailScreen: View {
    @Environment(CompanionClient.self) private var client
    let sessionId: UUID

    @State private var draft: String = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if let session = client.activeSession {
                            ForEach(session.messages) { message in
                                MessageBubble(message: message)
                                    .id(message.id)
                            }
                            if session.meta.isProcessing {
                                HStack(spacing: 8) {
                                    ProgressView().controlSize(.small)
                                    Text("Thinking…")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.top, 4)
                            }
                        } else {
                            HStack { Spacer(); ProgressView(); Spacer() }
                                .padding(.top, 60)
                        }
                    }
                    .padding()
                }
                .onChange(of: client.activeSession?.messages.last?.id) { _, newId in
                    if let id = newId {
                        withAnimation { proxy.scrollTo(id, anchor: .bottom) }
                    }
                }
            }

            Divider()

            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...5)
                    .focused($inputFocused)
                Button {
                    let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return }
                    client.sendPrompt(text)
                    draft = ""
                    inputFocused = false
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title)
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .navigationTitle(client.activeSession?.meta.title ?? "Session")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: sessionId) {
            client.subscribe(to: sessionId)
        }
        .onDisappear { client.unsubscribe() }
    }
}

private struct MessageBubble: View {
    let message: WireMessage

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 40) }
            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 6) {
                if !message.text.isEmpty {
                    Text(message.text)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(bubbleColor)
                        .clipShape(.rect(cornerRadius: 14))
                        .foregroundStyle(message.role == .user ? .white : .primary)
                        .textSelection(.enabled)
                }
                if !message.toolSummaries.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(message.toolSummaries, id: \.self) { summary in
                            Text(summary)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 4)
                }
            }
            if message.role == .assistant { Spacer(minLength: 40) }
        }
    }

    private var bubbleColor: Color {
        message.role == .user ? Color.accentColor : Color.gray.opacity(0.18)
    }
}
