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

        if updater.isConfigured {
            Form {
                Section("Automatic Updates") {
                    Toggle("Automatically check for updates", isOn: $updater.automaticallyChecksForUpdates)

                    Picker("Check frequency", selection: $updater.updateCheckInterval) {
                        ForEach(intervals, id: \.seconds) { interval in
                            Text(interval.label).tag(interval.seconds)
                        }
                    }
                    .disabled(!updater.automaticallyChecksForUpdates)
                }
                .sectionActions {
                    Button("Check for Updates…") {
                        updater.checkForUpdates()
                    }
                    .disabled(!updater.canCheckForUpdates)
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
}

#Preview {
    UpdatesSettingsView()
        .environment(UpdaterManager())
}
