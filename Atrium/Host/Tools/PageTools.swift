import Foundation
import MCP

/// `render_html`, which shows a finished HTML page inline in the chat.
@MainActor
final class PageTools: ToolKit {
    nonisolated static let renderHTML = "render_html"
    /// How Claude names `render_html` in its history and hooks.
    nonisolated static let claudeRenderHTML = "mcp__\(AtriumToolServer.name)__\(renderHTML)"

    let group = ToolGroup.pages

    func instructions(for caller: ToolCaller) -> String {
        """
        Atrium shows this chat to the user in its own app, on Mac, iPad and iPhone.
        Most answers need no page. Use `render_html` only when a visual makes the answer clearer than text would, such as data with a trend or comparison, or when the user asks to see something here (a diagram, mockup or report). A plain table or list belongs in Markdown in your reply, not a page. Never start a server or open a browser to show one. Show visuals here rather than as a claude.ai Artifact or any other hosted page; make one of those only when the user explicitly asks for it. A text description or a screenshot on disk does not show it. When the user wants an image file to post or send elsewhere, write a `.png` instead.
        """
    }

    private static let pageGuide = """
        Keep it light: one clear point, about a screen tall at most (under 600px). Help the user understand without overwhelming them; when there is more to show, put it behind tabs, a picker or toggles rather than making the page longer.
        One complete, self-contained HTML document; inline any <style> or <script> you still need. Remote URLs load as-is; local files do not, so inline any image as a data: URL.
        Layout: the page sits on the chat background at reply width (about 700px on Mac, narrower on iPad; iPhone opens it in a sheet). Keep the page, charts and tables unframed: no background, outer card, border, banner title or side padding. Give charts fixed pixel heights. Let content set the page's height: never use vh units or height:100% on html or body. Keep the top-right 120×44px clear for Atrium's buttons.
        Classes: Atrium styles the page to match the app. Use these instead of writing your own chrome, and never restyle them: .card (the only boxed surface; never nest it), .grid (equal columns that stack when narrow), .row (a wrapping inline group), .stat-label and .stat-value in a .card, .btn and .btn-primary, .muted, .small, .num (right-aligned numbers). Plain tables are already styled. Tabs: a .tabs element with role=tablist holding role=tab buttons whose aria-controls name role=tabpanel elements; mark one aria-selected=true and hide the other panels, and Atrium switches them. Add data-tooltip to any element or SVG mark for a hover or tap tooltip.
        Style: font weights 400 and 500 only. No custom font sizes; use .small for secondary text and 12px for SVG labels. Add no summary cards, filters or titles the user didn't need, and at most one short heading. Use series colors only on chart marks; keep values, labels and axes in --foreground or --muted-foreground. Keep gridlines thin and neutral, with no outlines on bars. Label values directly; add a legend only for two or more series.
        Theme: Atrium sets these CSS variables on :root for light and dark mode. Use them, not fixed colors: --foreground, --muted-foreground, --background, --card, --muted, --border, --popover, --primary (Atrium's green, for selected states and the first series) with --primary-foreground, --accent (a soft green wash for highlights) with --accent-foreground, --success, --warning, --destructive, --viz-series-1 to --viz-series-6, --font-sans, --font-mono, --radius.
        """

    let tools = [Tool(
        name: PageTools.renderHTML,
        title: "Render HTML",
        description: """
            Show a finished HTML page (chart, diagram, mockup) inline in this chat, above your final reply, when a visual explains more than text would or the user asks for one. Prefer it to a claude.ai Artifact or other hosted page, which you make only when the user explicitly asks for one. Call it once the page is final, just before you reply. Do not announce, describe or restate the page in your reply. To revise a page, call it again with the whole updated document; earlier versions stay in the chat.
            \(PageTools.pageGuide)
            """,
        inputSchema: [
            "type": "object",
            "properties": [
                "html": ["type": "string", "description": "A complete, self-contained HTML document."],
                "title": ["type": "string", "description": "A short name for the page, shown where it is opened."],
                "height": [
                    "type": "integer",
                    "description": "The page's expected height in CSS pixels at 700px wide, \(ChatPageStore.minimumHeight) to \(ChatPageStore.maximumHeight). Shown until the page measures itself."
                ]
            ],
            "required": ["html", "title"],
            "additionalProperties": false
        ],
        // It only adds to this chat, so agents that ask before other tools need not ask.
        annotations: .init(readOnlyHint: true, destructiveHint: false, idempotentHint: false, openWorldHint: false)
    )]

    func call(_ name: String, arguments: [String: Value], from caller: ToolCaller) async throws -> CallTool.Result {
        if let problem = ChatPageStore.problem(html: arguments["html"]?.stringValue, title: arguments["title"]?.stringValue) {
            throw ToolError(problem)
        }
        // Atrium shows the page from the agent's own history, where this call's input already is.
        return .text("Shown to the user above your reply. Don't mention or describe the page; reply with only what it doesn't already say.")
    }
}
