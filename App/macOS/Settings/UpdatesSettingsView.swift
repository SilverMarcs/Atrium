import SwiftUI

struct UpdatesSettingsView: View {
    @Environment(UpdaterManager.self) private var updater

    /// User-facing labels for the supported check intervals.
    private let intervals: [(label: String, seconds: TimeInterval)] = [
        ("Hourly", 3_600),
        ("Daily", 86_400),
        ("Weekly", 604_800),
        ("Monthly", 2_592_000),
    ]

    var body: some View {
        @Bindable var updater = updater

        Group {
            if updater.isConfigured {
                Form {
                    Section {
                        Picker("Update channel", selection: $updater.channel) {
                            ForEach(UpdateChannel.allCases) { channel in
                                Text(channel.label).tag(channel)
                            }
                        }
                    } footer: {
                        Text("Nightly gets new features as soon as they're built. Stable releases always work with the iPhone app on the App Store.")
                            .foregroundStyle(.secondary)
                    }

                    Section {
                        Toggle("Automatically check for updates", isOn: $updater.automaticallyChecksForUpdates)

                        Picker("Check frequency", selection: $updater.updateCheckInterval) {
                            ForEach(intervals, id: \.seconds) { interval in
                                Text(interval.label).tag(interval.seconds)
                            }
                        }
                        .disabled(!updater.automaticallyChecksForUpdates)
                    }
                }
                .formStyle(.grouped)
            } else {
                ContentUnavailableView(
                    "Automatic Updates Unavailable",
                    systemImage: "arrow.down.circle",
                    description: Text("This build of Atrium does not support automatic updates.")
                )
            }
        }
        .navigationTitle("Updates")
        .toolbar {
            if updater.isConfigured {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        updater.checkForUpdates()
                    } label: {
                        Label("Check for Updates…", systemImage: "arrow.clockwise")
                    }
                    .disabled(!updater.canCheckForUpdates)
                    .help("Check for Atrium updates now")
                }
            } else {
                ToolbarHeightPlaceholder()
            }
        }
    }
}

#Preview {
    UpdatesSettingsView()
        .environment(UpdaterManager())
}
