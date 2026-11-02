import Foundation

/// What Atrium tells the agents it runs: Claude appends it to its system
/// prompt and Codex takes it as developer instructions. It's built from fixed
/// blocks, and which ones a chat gets is settled when the chat is created and
/// kept for every launch after, so its cached prompt prefix never changes.
nonisolated enum AgentInstructions {
    /// A block Settings → Integrations can leave out of new chats. Showing
    /// images is always there.
    enum Block: String, Codable, Sendable {
        /// Showing HTML pages, such as charts and diagrams.
        case pages
        /// Handing work to other sessions with the `atrium` command.
        case orchestrator
    }

    static func text(_ blocks: Set<Block>) -> String {
        [base, blocks.contains(.pages) ? pages : nil, blocks.contains(.orchestrator) ? orchestrator : nil]
            .compactMap(\.self).joined(separator: "\n\n")
    }

    private static let base = """
        # Atrium

        Atrium shows this chat to the user in its own app, on Mac, iPad and iPhone.

        To show an image, such as a screenshot, plot or generated picture, put it in your reply as Markdown: `![short caption](/absolute/path.png)`. It loads from this Mac on every device whenever the chat is viewed, so give each image its own file name and leave it in place: overwriting or deleting the file changes or breaks earlier messages.
        """

    private static let pages = """
        Most answers need no page. Show an HTML page only when a visual makes the answer clearer than text or an image would, such as data with a trend or comparison, or when the user asks to see something here (a diagram, mockup or report). A plain table or list belongs in Markdown, not a page. Never start a server or open a browser to show one. Show visuals here rather than as a claude.ai Artifact or any other hosted page; make one of those only when the user explicitly asks for it. A text description or a bare file path does not show it. When the user wants an image file to post or send elsewhere, write a `.png` instead.

        ## Pages

        To show a page, write one complete HTML document in your final reply, in a fenced block whose info string is `atrium-page` and a short title:

        ```atrium-page title="Build times this week"
        <!doctype html>
        <html>…</html>
        ```

        Atrium shows the page above your reply's text instead of the block. Write it once it's final, at most one per reply, and don't announce, describe or restate it in your text. If the HTML has a line starting with three backticks, fence the block with four. To revise a page, write it again in full under the same title; earlier versions stay in the chat.

        Keep it light: one clear point, about a screen tall at most (under 600px). Help the user understand without overwhelming them; when there is more to show, put it behind tabs, a picker or toggles rather than making the page longer.
        Inline any <style> or <script> you need. Reference local images by absolute path, as in <img src="/path/to/chart.png">; remote URLs load as-is.
        Layout: the page sits on the chat background at reply width (about 700px on Mac, narrower on iPad; iPhone opens it in a sheet). Keep the page, charts and tables unframed: no background, outer card, border, banner title or side padding. Give charts fixed pixel heights. Let content set the page's height: never use vh units or height:100% on html or body. Keep the top-right 120×44px clear for Atrium's buttons.
        Classes: Atrium styles the page to match the app. Use these instead of writing your own chrome, and never restyle them: .card (the only boxed surface; never nest it), .grid (equal columns that stack when narrow), .row (a wrapping inline group), .stat-label and .stat-value in a .card, .btn and .btn-primary, .muted, .small, .num (right-aligned numbers). Plain tables are already styled. Tabs: a .tabs element with role=tablist holding role=tab buttons whose aria-controls name role=tabpanel elements; mark one aria-selected=true and hide the other panels, and Atrium switches them. Add data-tooltip to any element or SVG mark for a hover or tap tooltip.
        Style: font weights 400 and 500 only. No custom font sizes; use .small for secondary text and 12px for SVG labels. Add no summary cards, filters or titles the user didn't need, and at most one short heading. Use series colors only on chart marks; keep values, labels and axes in --foreground or --muted-foreground. Keep gridlines thin and neutral, with no outlines on bars. Label values directly; add a legend only for two or more series.
        Theme: Atrium sets these CSS variables on :root for light and dark mode. Use them, not fixed colors: --foreground, --muted-foreground, --background, --card, --muted, --border, --popover, --primary (Atrium's green, for selected states and the first series) with --primary-foreground, --accent (a soft green wash for highlights) with --accent-foreground, --success, --warning, --destructive, --viz-series-1 to --viz-series-6, --font-sans, --font-mono, --radius.
        """

    private static let orchestrator = """
        ## Other agents

        For cross-provider delegation, always use `atrium start` and `atrium send`; `atrium help` explains them. Never launch another provider directly through shell commands or subprocesses. Atrium needs this flow to track parent sessions, deliver results, and keep delegated sessions out of the main task list. Native subagent tools remain allowed.

        Start or prompt a session, then end your turn: Atrium sends you its result, and any question it asks, as a new message. Delegate only when it helps, to a few sessions at most, and never hand on work that was handed to you.
        """
}

/// The instruction blocks each chat Atrium runs was created with, by task ID.
/// Chats from before blocks were recorded have the base and pages, as they
/// always did. Forks and side chats share their chat's, so they reuse its
/// cached prompt too.
@MainActor
final class ChatInstructions {
    private let settings: IntegrationSettings
    private let file: URL
    private var blocks: [String: Set<AgentInstructions.Block>]

    init(settings: IntegrationSettings, file: URL = HostStorage.directory.appending(path: "chat-instructions.json")) {
        self.settings = settings
        self.file = file
        blocks = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([String: Set<AgentInstructions.Block>].self, from: $0) } ?? [:]
    }

    /// Reads what chats were created with, as a connection that only reads does.
    convenience init() {
        self.init(settings: IntegrationSettings())
    }

    /// The blocks a chat created now gets: those Settings turns on.
    var forNewChat: Set<AgentInstructions.Block> {
        var blocks: Set<AgentInstructions.Block> = []
        if settings.isVisualizationsEnabled { blocks.insert(.pages) }
        if settings.isOrchestratorEnabled { blocks.insert(.orchestrator) }
        return blocks
    }

    func blocks(for id: String) -> Set<AgentInstructions.Block> {
        blocks[id] ?? [.pages]
    }

    func text(for id: String) -> String {
        AgentInstructions.text(blocks(for: id))
    }

    func record(_ blocks: Set<AgentInstructions.Block>, for id: String) {
        guard self.blocks[id] != blocks else { return }
        self.blocks[id] = blocks
        guard let data = try? JSONEncoder().encode(self.blocks) else { return }
        try? data.write(to: file, options: .atomic)
    }
}
