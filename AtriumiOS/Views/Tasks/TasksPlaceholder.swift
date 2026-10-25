import SwiftUI

struct TasksPlaceholder: View {
    let isLoaded: Bool
    let isSearching: Bool
    let isEmpty: Bool

    var body: some View {
        if !isLoaded {
            ProgressView()
                .controlSize(.large)
        } else if isEmpty {
            if isSearching {
                ContentUnavailableView.search
            } else {
                ContentUnavailableView(
                    "No Tasks",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("Start a task here or on your Mac.")
                )
            }
        }
    }
}
