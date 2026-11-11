import AtriumClient
import SwiftUI

extension EnvironmentValues {
    /// Opens one of the subagents of the task on screen, over that task.
    @Entry var openSubagent: (TaskRef) -> Void = { _ in }
    /// Opens the side chat of the task on screen, over that task.
    @Entry var openSideChat: (TaskRef) -> Void = { _ in }
    /// Opens a new side chat in place of the one on screen.
    @Entry var replaceSideChat: (TaskRef) -> Void = { _ in }
}
