import AtriumClient
import SwiftUI

extension View {
    /// Takes dragged tasks into a section: a row takes them into its own
    /// section, and a header into its section whether it's expanded or not.
    /// It only takes tasks that can move there, and is highlighted while they hover.
    func taskDropTarget(isEnabled: Bool, perform: @escaping ([TaskRef]) -> Void) -> some View {
        modifier(TaskDropTarget(isEnabled: isEnabled, perform: perform))
    }
}

private struct TaskDropTarget: ViewModifier {
    let isEnabled: Bool
    let perform: ([TaskRef]) -> Void
    @State private var isTargeted = false

    func body(content: Content) -> some View {
        content
            .background {
                if isTargeted {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(.tint.opacity(0.25))
                        .padding(-4)
                }
            }
            .dropDestination(for: TaskDrag.self, isEnabled: isEnabled) { drags, _ in
                perform(drags.flatMap(\.tasks))
            }
            .onDropSessionUpdated { session in
                isTargeted = switch session.phase {
                case .entering, .active: isEnabled
                default: false
                }
            }
    }
}
