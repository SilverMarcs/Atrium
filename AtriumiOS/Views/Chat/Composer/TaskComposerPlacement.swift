import SwiftUI

/// Places the task's composer for the device: the bottom-bar search field on
/// iPhone, and the inline input bar along the bottom edge on iPad.
struct TaskComposerPlacement: ViewModifier {
    let composer: TaskComposer
    let task: WireTask?
    let prompt: String
    /// Sends the draft, returning whether it was sent.
    let submit: () -> Bool

    func body(content: Content) -> some View {
        if UIDevice.current.userInterfaceIdiom == .phone {
            content
                .searchFieldComposer(composer, prompt: prompt, submit: submit)
        } else {
            content
                .safeAreaBar(edge: .bottom, spacing: 0) {
                    TaskInputBar(task: task, prompt: prompt, submit: submit)
                }
        }
    }
}

extension View {
    /// Adds the task's prompt composer where the device shows it.
    func taskComposer(_ composer: TaskComposer, task: WireTask?, prompt: String, submit: @escaping () -> Bool) -> some View {
        modifier(TaskComposerPlacement(composer: composer, task: task, prompt: prompt, submit: submit))
    }
}
