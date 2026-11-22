import SwiftUI

/// How a task list row names its host, when several are listed: the host's
/// icon, its name, or both.
enum TaskRowHostLabel: String, CaseIterable, Identifiable, LabelStyle {
    case iconAndName
    case icon
    case name

    static let key = "taskRowHostLabel"

    var id: Self { self }

    var title: String {
        switch self {
        case .iconAndName: "Icon and Name"
        case .icon: "Icon Only"
        case .name: "Name Only"
        }
    }

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            if self != .name { configuration.icon }
            if self != .icon { configuration.title }
        }
    }
}

/// Settings' choice of how task list rows name their host.
struct TaskRowHostLabelPicker: View {
    var title = "Host in task list"
    var showsSubtitle = true
    @AppStorage(TaskRowHostLabel.key) private var label = TaskRowHostLabel.iconAndName

    var body: some View {
        Picker(selection: $label) {
            ForEach(TaskRowHostLabel.allCases) { label in
                Text(label.title).tag(label)
            }
        } label: {
            Text(title)
            if showsSubtitle {
                Text("When tasks from several hosts are listed")
            }
        }
    }
}
