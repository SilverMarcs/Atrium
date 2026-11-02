import SwiftUI

/// What the task list shows when it has no rows: a spinner while hosts are
/// still being reached or loading, else why it's empty.
struct TasksPlaceholder: View {
    let isLoaded: Bool
    /// Hosts whose tasks haven't arrived because they aren't connected yet.
    let connectingHostIDs: [String]
    let isRefreshing: Bool
    let isSearching: Bool
    let isEmpty: Bool
    /// Whether hosts are still being reached, for as long as the title says
    /// it's reconnecting, before an empty list is taken at its word.
    @State private var isReachingHosts = true

    var body: some View {
        ZStack {
            if !isLoaded || (isEmpty && (isReachingHosts || isRefreshing)) {
                ProgressView()
                    .controlSize(.large)
            } else if isEmpty {
                if isSearching {
                    ContentUnavailableView.search
                } else {
                    ContentUnavailableView(
                        "No Tasks",
                        systemImage: "bubble.left.and.bubble.right",
                        description: Text("Start a task here or on your host.")
                    )
                }
            }
        }
        .task(id: connectingHostIDs) {
            guard !connectingHostIDs.isEmpty else {
                isReachingHosts = false
                return
            }
            isReachingHosts = true
            // Matches ConnectionStatusSubtitle's wait before it says a host can't be reached.
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled else { return }
            isReachingHosts = false
        }
    }
}
