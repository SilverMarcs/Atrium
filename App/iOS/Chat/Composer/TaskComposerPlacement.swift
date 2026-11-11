import AtriumClient
import AtriumProtocol
import SwiftUI

/// Places the task's composer for the device: the bottom-bar search field on
/// iPhone, and the inline input bar along the bottom edge on iPad.
struct TaskComposerPlacement: ViewModifier {
    let composer: TaskComposer
    let item: HostTask?
    let prompt: String
    /// Sends the draft from the field at the given frame, if known, returning
    /// whether it was sent.
    let submit: (CGRect?) -> Bool

    func body(content: Content) -> some View {
        // A subagent answers only to its own agent.
        if item?.task.isSubagent == true {
            content
        } else if UIDevice.current.userInterfaceIdiom == .phone {
            content
                .searchFieldComposer(composer, prompt: prompt, submit: submit)
        } else {
            content
                .safeAreaBar(edge: .bottom, spacing: 0) {
                    TaskInputBar(item: item, prompt: prompt, submit: submit)
                }
        }
    }
}

extension View {
    /// Adds the task's prompt composer where the device shows it.
    func taskComposer(_ composer: TaskComposer, item: HostTask?, prompt: String, submit: @escaping (CGRect?) -> Bool) -> some View {
        modifier(TaskComposerPlacement(composer: composer, item: item, prompt: prompt, submit: submit))
    }
}
