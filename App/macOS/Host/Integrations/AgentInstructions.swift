import Foundation

/// What Atrium tells the agents it runs: Claude appends it to its system
/// prompt and Codex takes it as developer instructions. It's built from fixed
/// blocks, and which ones a chat gets is settled when the chat is created and
/// kept for every launch after, so its cached prompt prefix never changes.
nonisolated enum AgentInstructions {
    /// A block Settings → Integrations can leave out of new chats. Showing
    /// images is always there.
    enum Block: String, Codable, Sendable {
        /// Showing HTML pages, such as charts and diagrams, with the `show_page` tool.
        case pages
        /// Handing work to other sessions with Atrium's session tools.
        case orchestrator
        /// Asking the user for secrets with the `request_secret` tool.
        case secrets
        /// Browsing with the chat's own browser and Atrium's `browser_*` tools.
        case browser
    }

    /// The blocks, then the project's other folders when it has any, last so
    /// the rest of the prompt stays cached when they change.
    static func text(_ blocks: Set<Block>, directory: String? = nil, otherFolders: [String] = []) -> String {
        [
            base, blocks.contains(.pages) ? pages : nil, blocks.contains(.orchestrator) ? orchestrator : nil,
            blocks.contains(.secrets) ? secrets : nil, blocks.contains(.browser) ? browser : nil,
            directory.flatMap { otherFolders.isEmpty ? nil : folders(working: $0, others: otherFolders) },
        ]
            .compactMap(\.self).joined(separator: "\n\n")
    }

    /// Names the folders a project spans beside the one the agent works in.
    static func folders(working directory: String, others: [String]) -> String {
        let lines = ([directory] + others).map { path in
            let kind = GitCheckout(rootedAt: URL(filePath: path, directoryHint: .isDirectory)) == nil ? "folder" : "Git repository"
            return "- \(URL(filePath: path).lastPathComponent) (\(kind)): `\(path)`"
        }
        return """
            ## Project folders

            This project spans several folders. You work in the first; the others are part of the project too, and you may read and change them. Run Git commands inside the repository you change, and commit each repository on its own.

            \(lines.joined(separator: "\n"))
            """
    }

    private static let base = """
        # Atrium

        Atrium shows this chat to the user in its own app, on Mac, iPad and iPhone.

        To show an image, such as a screenshot, plot or generated picture, put it in your reply as Markdown: `![short caption](/absolute/path.png)`. It loads from this Mac on every device whenever the chat is viewed, so give each image its own file name and leave it in place: overwriting or deleting the file changes or breaks earlier messages.
        """

    private static let pages = """
        Most answers need no page. Show an HTML page only when a visual makes the answer clearer than text or an image would, such as data with a trend or comparison, or when the user asks to see something here (a diagram, mockup or report). A plain table or list belongs in Markdown, not a page. Never start a server or open a browser to show one. Show visuals here rather than as a claude.ai Artifact or any other hosted page; make one of those only when the user explicitly asks for it. A text description or a bare file path does not show it. When the user wants an image file to post or send elsewhere, write a `.png` instead.

        ## Pages

        To show a page, write one complete HTML document to its own `.html` file in a temporary folder, then call Atrium's `show_page` tool with a short title and the file's absolute path. Atrium shows the page inline in your reply, as tall as it is. Show it once it's final, at most one per reply, and don't announce, describe or restate it in your text. To revise a page, edit its file rather than rewriting it, then show it again; Atrium keeps a copy of each version a reply showed, so earlier replies keep theirs.

        Keep it light: one clear point, about a screen tall at most (under 600px). Help the user understand without overwhelming them; when there is more to show, put it behind tabs, a picker or toggles rather than making the page longer.
        Inline any <style> or <script> you need. Reference local images by absolute path, as in <img src="/path/to/chart.png">, or relative to the task folder; remote URLs load as-is. JavaScript and CSS can build image paths normally. Keep images outside the task folder together, and write their absolute folder path as a quoted string ending in `/`, such as `const base='/path/to/images/';`. Atrium lets that page load images from that folder. Keep image files available for later viewing.
        Layout: the page sits in the chat at the reply's width, up to about 900px on Mac and down to 320px on iPhone, so it must fit any width from 320px up: let rows wrap and grids reflow, size charts and images to the width (SVGs with a viewBox and width:100%), and set no fixed width over 320px. Keep the page, charts and tables unframed: no outer card, border, banner title or side padding, and no background on html, body or a page-wide wrapper, so the window's own background shows through. Give charts fixed pixel heights.
        Classes: Atrium styles the page to match the app. Use these instead of writing your own chrome, and never restyle them: .card (the only boxed surface; never nest it), .grid (equal columns that stack when narrow), .row (a wrapping inline group), .stat-label and .stat-value in a .card, .btn and .btn-primary, .muted, .small, .num (right-aligned numbers). Plain tables are already styled. Tabs: a .tabs element with role=tablist holding role=tab buttons whose aria-controls name role=tabpanel elements; mark one aria-selected=true and hide the other panels, and Atrium switches them. Add data-tooltip to any element or SVG mark for a hover or tap tooltip. For an icon, write <i data-symbol="chart.bar.fill"></i> with any SF Symbol name; it takes the text's size and color. Draw an SVG icon only when no SF Symbol fits.
        Style: font weights 400 and 500 only. No custom font sizes; use .small for secondary text and 12px for SVG labels. Add no summary cards, filters or titles the user didn't need, and at most one short heading. Use series colors only on chart marks; keep values, labels and axes in --foreground or --muted-foreground. Keep gridlines thin and neutral, with no outlines on bars. Label values directly; add a legend only for two or more series.
        Theme: Atrium sets these CSS variables on :root for light and dark mode. Use them, not fixed colors: --foreground, --muted-foreground, --background (only for marks that cut through others, never as a fill), --card, --muted, --border, --popover, --primary (Atrium's green, for selected states and the first series) with --primary-foreground, --accent (a soft green wash for highlights) with --accent-foreground, --success, --warning, --destructive, --viz-series-1 to --viz-series-6, --font-sans, --font-mono, --radius.
        """

    private static let orchestrator = """
        ## Other agents

        For cross-provider delegation, always use Atrium's `start_session` and `send_prompt` tools. Never launch another provider directly through shell commands or subprocesses. Atrium needs this flow to track parent sessions, deliver results, and keep delegated sessions out of the main task list. Native subagent tools remain allowed.

        Start or prompt a session, then end your turn: Atrium sends you any question it asks as a new message, which you answer with `respond`, and its result once every session you handed work to is done, all results together. `send_prompt` to a session that's still working queues your prompt to start its next turn once the current one ends; set `steer` only when the agent must take it in now, such as a correction to what it's doing. Delegate only when it helps, to a few sessions at most, and never hand on work that was handed to you.

        Only when the user explicitly asks for a separate session of its own, one they'll continue themselves, start it with `standalone` set: it's listed as the user's own and doesn't report back to you.

        When the user asks you to consult several models, start one session per model they name (or a mix from `list_projects` if they don't), each with the same self-contained brief, asking for its own approach without editing files, then end your turn. Ask one to clarify with `send_prompt` when its idea is unclear. Then weigh the ideas, combine the best of them, and continue the user's request with that, saying which ideas you took from whom.
        """

    private static let secrets = """
        ## Secrets

        When a step needs a secret only the user has, such as an API key, token or password, never ask for it in the chat or tell the user to paste it. Call Atrium's `request_secret` tool as soon as you need it, with what it is, what it's for and where to find it, and its sign-in or setup page when there is one; ask for values that go together, such as an email and password, in one call. The user answers in a private question, and the tool returns owner-only files holding the values. Read a file only inside the command that uses it, as in `"$(cat <file>)"`, and never print, log, commit or copy its contents. Don't ask again after the user declines.
        """

    private static let browser = """
        ## Browser

        To test what you build for the web, and for any browsing a task needs, use Atrium's `browser_*` tools rather than computer use or another browser, unless the user names one. Your chat has one tab (WebKit), which the user sees beside the chat. Test like a person would: open the page, act with `browser_act` (real clicks and keys), and check the results in the snapshot it returns, `browser_logs` for console errors and failed requests, and `browser_viewport` for phone and tablet layouts. Work from snapshots and their refs; ask for a screenshot only when how the page looks matters.
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
        var blocks: Set<AgentInstructions.Block> = [.secrets, .browser]
        if settings.isVisualizationsEnabled { blocks.insert(.pages) }
        if settings.isOrchestratorEnabled { blocks.insert(.orchestrator) }
        return blocks
    }

    func blocks(for id: String) -> Set<AgentInstructions.Block> {
        blocks[id] ?? [.pages]
    }

    /// The folders of the project a chat's folder belongs to, and which of
    /// them the chat works in, for a folder in a project. The host sets it.
    var projectFolders: (String) -> (all: [String], own: String)? = { _ in nil }

    /// A chat's instructions, naming its project's other folders when it has any.
    func text(for id: String, directory: String) -> String {
        text(blocks(for: id), directory: directory)
    }

    /// Instructions with these blocks, naming the project's other folders when it has any.
    func text(_ blocks: Set<AgentInstructions.Block>, directory: String) -> String {
        AgentInstructions.text(blocks, directory: directory, otherFolders: otherFolders(for: directory))
    }

    /// The project's folders besides the one a chat works in, which it may also change.
    func otherFolders(for directory: String) -> [String] {
        guard let folders = projectFolders(directory) else { return [] }
        return folders.all.filter { $0 != folders.own }
    }

    func record(_ blocks: Set<AgentInstructions.Block>, for id: String) {
        guard self.blocks[id] != blocks else { return }
        self.blocks[id] = blocks
        guard let data = try? JSONEncoder().encode(self.blocks) else { return }
        try? data.write(to: file, options: .atomic)
    }
}
