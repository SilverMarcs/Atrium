import SwiftUI

struct TaskFilterMenu: View {
    @Binding var filter: TaskListFilter

    var body: some View {
        Menu {
            Picker("Show", selection: $filter.animation()) {
                ForEach(TaskListFilter.allCases) { filter in
                    Label(filter.title, systemImage: filter.systemImage)
                }
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease")
                .foregroundStyle(filter != .all ? .accent : .primary)
        }
        .accessibilityLabel("Filter")
    }
}
