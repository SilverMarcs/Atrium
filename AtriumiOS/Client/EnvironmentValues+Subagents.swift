import AtriumClient
import SwiftUI

extension EnvironmentValues {
    /// Opens one of the subagents of the task on screen, over that task.
    @Entry var openSubagent: (TaskRef) -> Void = { _ in }
}
