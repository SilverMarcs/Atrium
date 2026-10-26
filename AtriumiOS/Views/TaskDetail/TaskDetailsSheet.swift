import SwiftUI

/// The task's status, agent and project.
struct TaskDetailsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let task: WireTask

    var body: some View {
        NavigationStack {
            TaskSummaryView(task: task)
                .navigationTitle("Details")
                .toolbarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(role: .close) { dismiss() }
                    }
                }
        }
        .presentationDetents([.medium, .large])
    }
}
