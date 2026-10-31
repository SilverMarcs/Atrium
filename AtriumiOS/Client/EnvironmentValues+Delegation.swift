import AtriumClient
import SwiftUI

extension EnvironmentValues {
    /// Opens a session the task on screen delegated work to, over that task.
    @Entry var openDelegatedTask: (TaskRef) -> Void = { _ in }
}
