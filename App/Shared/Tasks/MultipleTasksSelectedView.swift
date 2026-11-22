import SwiftUI

/// The detail column while several tasks are selected in the list.
struct MultipleTasksSelectedView: View {
    var body: some View {
        Text("Multiple items selected")
            .font(.title3)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
