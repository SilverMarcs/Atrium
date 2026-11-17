import AtriumClient
import AtriumProtocol
import Observation

/// What a chat shows in the pane beside it.
enum SidePaneContent: Equatable {
    /// A page an agent showed in the chat.
    case page(ChatPageBlock)
}

/// The pane beside each chat, for the window's lifetime. Each chat keeps its
/// own, so coming back to a chat shows what it showed.
@MainActor
@Observable
final class SidePanes {
    private var contents: [TaskRef: SidePaneContent] = [:]
    /// The newest page each chat had when last seen, by key; nil when it had none.
    @ObservationIgnored private var newestPageKeys: [TaskRef: String?] = [:]

    func content(for task: TaskRef) -> SidePaneContent? {
        contents[task]
    }

    func show(_ content: SidePaneContent, for task: TaskRef) {
        contents[task] = content
    }

    func close(for task: TaskRef) {
        contents[task] = nil
    }

    /// Notes the page a chat's newest reply ends with, and says whether an
    /// agent just showed it. The first time a chat is seen, its pages are
    /// older than that, so none of them is new.
    func noteNewestPage(_ page: ChatPageBlock?, in task: TaskRef) -> Bool {
        let key = page?.page.key
        guard let known = newestPageKeys.updateValue(key, forKey: task) else { return false }
        return key != nil && key != known
    }
}

extension AppModel {
    /// Shows something beside a chat. The pane opening closes the inspector,
    /// which the person can open again alongside it.
    func showInSidePane(_ content: SidePaneContent, for task: TaskRef) {
        if sidePanes.content(for: task) == nil { showingInspector = false }
        sidePanes.show(content, for: task)
    }
}
