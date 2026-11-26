import SwiftUI

struct PreviewRelaySettings: View {
    @State private var configured = false
    @State private var presented = false
    @State private var keyID = ""
    @State private var token = ""
    @State private var error: String?
    @State private var saving = false

    var body: some View {
        LabeledContent("Live Preview Relay") {
            Button(configured ? "Configured…" : "Set Up…") {
                keyID = CloudflareTURN.key?.id ?? ""
                token = ""
                error = nil
                presented = true
            }
        }
        .onAppear { configured = CloudflareTURN.key != nil }
        .sheet(isPresented: $presented) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Cloudflare Realtime TURN").font(.headline)
                Text("Relays live previews when your Mac and companion can’t connect directly.")
                    .foregroundStyle(.secondary)
                TextField("TURN Key ID", text: $keyID)
                SecureField("TURN API Token", text: $token)
                if let error { Text(error).foregroundStyle(.red) }
                HStack {
                    Link("Cloudflare Dashboard", destination: URL(string: "https://dash.cloudflare.com/?to=/:account/realtime/turn")!)
                    Spacer()
                    if configured {
                        Button("Remove", role: .destructive, action: remove)
                    }
                    Button("Cancel", role: .cancel) { presented = false }
                    Button("Save", action: save)
                        .keyboardShortcut(.defaultAction)
                        .disabled(keyID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(24)
            .frame(width: 430)
            .disabled(saving)
            .interactiveDismissDisabled(saving)
            .onDisappear { token = "" }
        }
    }

    private func save() {
        let key = CloudflareTURN.Key(
            id: keyID.trimmingCharacters(in: .whitespacesAndNewlines),
            token: token.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        saving = true
        error = nil
        Task {
            defer { saving = false }
            do {
                _ = try await key.iceServers()
                try CloudflareTURN.save(key)
                configured = true
                presented = false
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func remove() {
        do {
            try CloudflareTURN.remove()
            configured = false
            presented = false
        } catch {
            self.error = error.localizedDescription
        }
    }
}
