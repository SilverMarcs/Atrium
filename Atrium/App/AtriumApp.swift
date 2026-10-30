import SwiftUI

@main
struct AtriumApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var app = AppModel()
    @State private var updater = UpdaterManager()
    @State private var dictationSettings = DictationSettings()

    var body: some Scene {
        Window("Atrium", id: "atrium") {
            ContentView()
                .environment(app)
                .environment(dictationSettings)
                .frame(minWidth: 600, minHeight: 400)
        }
        .defaultSize(width: 900, height: 600)
        .commands {
            AppCommands(app: app, updater: updater)
        }

        WindowGroup("Diff", for: GitCommitDiffSheetItem.self) { $item in
            if let item {
                GitCommitDiffWindow(item: item)
                    .environment(app)
            }
        }
        .defaultSize(width: 1100, height: 700)
        .restorationBehavior(.disabled)

        Window("About Atrium", id: "about") {
            AboutView()
                .containerBackground(.regularMaterial, for: .window)
                .toolbar(removing: .title)
                .toolbarBackground(.hidden, for: .windowToolbar)
                .windowMinimizeBehavior(.disabled)
        }
        .windowBackgroundDragBehavior(.enabled)
        .windowResizability(.contentSize)
        .restorationBehavior(.disabled)

        Settings {
            SettingsView()
                .environment(updater)
                .environment(app)
                .environment(dictationSettings)
        }
    }
}
