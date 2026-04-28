import SwiftUI

@main
struct AtriumiOSApp: App {
    @State private var client = CompanionClient()

    var body: some Scene {
        WindowGroup {
            CompanionRootView()
                .environment(client)
        }
    }
}
