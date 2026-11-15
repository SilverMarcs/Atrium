import SwiftUI

/// Submenus have no checked state in SwiftUI; keep the native row and
/// mark the selected model with the system checkmark image.
struct TaskModelOptionLabel: View {
    let title: String
    let isSelected: Bool

    var body: some View {
        #if os(iOS)
        if isSelected {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
        #else
        Text(title)
        #endif
    }
}
