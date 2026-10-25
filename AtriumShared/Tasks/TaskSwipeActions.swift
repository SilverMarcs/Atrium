import SwiftUI

/// Sidebar swipe actions, icon only: settle and snooze on the leading edge,
/// delete and read state on the trailing edge.
struct TaskSwipeActions: ViewModifier {
    let state: TaskMenuState
    let perform: (TaskMenuAction) -> Void

    func body(content: Content) -> some View {
        content
            .swipeActions(edge: .leading) {
                TaskActionButton(action: state.settleAction, state: state, perform: perform)
                    .labelStyle(.iconOnly)
                if let snoozeAction = state.snoozeAction {
                    TaskActionButton(action: snoozeAction, state: state, perform: perform)
                        .labelStyle(.iconOnly)
                }
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                if state.supportsDeletion {
                    TaskActionButton(action: .delete, state: state, perform: perform)
                        .labelStyle(.iconOnly)
                }
                TaskActionButton(action: state.readAction, state: state, perform: perform)
                    .labelStyle(.iconOnly)
            }
    }
}

extension View {
    func taskSwipeActions(_ state: TaskMenuState, perform: @escaping (TaskMenuAction) -> Void) -> some View {
        modifier(TaskSwipeActions(state: state, perform: perform))
    }
}
