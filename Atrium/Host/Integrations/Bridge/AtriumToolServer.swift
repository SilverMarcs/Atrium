import Foundation

/// Atrium's MCP server, which every agent Atrium starts can call over the
/// bridge. Each request gets a JSON reply; there is no event stream.
nonisolated enum AtriumToolServer {
    /// The name agents know the server by. Claude prefixes its tools with `mcp__atrium__`.
    static let name = "atrium"
    static let renderHTML = "render_html"
    /// How Claude names `render_html` in its history and hooks.
    static let claudeRenderHTML = "mcp__\(name)__\(renderHTML)"

    private static let instructions = """
        Atrium shows this chat to the user in its own app, on Mac, iPad and iPhone.
        Most answers need no page. Use `render_html` only when a visual makes the answer clearer than text would, such as data with a trend or comparison, or when the user asks to see something here (a diagram, table, mockup or report). Never start a server or open a browser to show one. A text description or a screenshot on disk does not show it. When the user wants an image file to post or send elsewhere, write a `.png` instead.
        """

    private static let pageGuide = """
        Keep it light: one clear point, about a screen tall at most (under 600px). Help the user understand without overwhelming them; when there is more to show, put it behind tabs, a picker or toggles rather than making the page longer.
        One complete, self-contained HTML document: inline <style> and <script>. Remote URLs load as-is; local files do not, so inline any image as a data: URL.
        Layout: the page sits on the chat background at reply width (about 700px on Mac, narrower on iPad; iPhone opens it in a sheet). Leave html and body without a background color, outer card, border, banner title or side padding. A box that needs its own background gets 16px padding and var(--radius) corners. Give charts fixed pixel heights. Let content set the page's height: never use vh units or height:100% on html or body.
        Theme: Atrium sets these CSS variables on :root for light and dark mode. Use them, not fixed colors: --background, --foreground, --muted-foreground, --card, --border, --accent, --accent-foreground, --success, --warning, --destructive, --chart-1 to --chart-5, --font-sans, --font-mono, --radius. The base sheet already sets the text color and font.
        """

    private static let tools: [[String: Any]] = [[
        "name": renderHTML,
        "title": "Render HTML",
        "description": """
            Show a finished HTML page (chart, diagram, table, mockup) inline in this chat, above your final reply, when a visual explains more than text would or the user asks for one. Call it once the page is final, just before you reply. Do not announce, describe or restate the page in your reply. To revise a page, call it again with the whole updated document; earlier versions stay in the chat.
            \(pageGuide)
            """,
        "inputSchema": [
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
        "annotations": ["readOnlyHint": true, "destructiveHint": false, "idempotentHint": false, "openWorldHint": false]
    ]]

    /// The reply to one JSON-RPC message, or nil for a notification.
    static func respond(to body: Data) -> Data? {
        guard let request = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let method = request["method"] as? String else {
            return reply(id: NSNull(), error: (-32700, "Parse error"))
        }
        // Notifications, such as `notifications/initialized`, carry no id and get no reply.
        guard let id = request["id"] else { return nil }
        let params = request["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            return reply(id: id, result: [
                "protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": name, "title": "Atrium", "version": "1.0"],
                "instructions": instructions
            ])
        case "ping":
            return reply(id: id, result: [:])
        case "tools/list":
            return reply(id: id, result: ["tools": tools])
        case "tools/call":
            return reply(id: id, result: call(params["name"] as? String, arguments: params["arguments"] as? [String: Any] ?? [:]))
        default:
            return reply(id: id, error: (-32601, "Method not found"))
        }
    }

    private static func call(_ tool: String?, arguments: [String: Any]) -> [String: Any] {
        guard tool == renderHTML else { return result("Unknown tool \(tool ?? "").", isError: true) }
        if let problem = ChatPageStore.problem(html: arguments["html"] as? String, title: arguments["title"] as? String) {
            return result(problem, isError: true)
        }
        // Atrium shows the page from the agent's own history, where this call's input already is.
        return result("Shown to the user above your reply. Don't mention or describe the page; reply with only what it doesn't already say.", isError: false)
    }

    private static func result(_ text: String, isError: Bool) -> [String: Any] {
        ["content": [["type": "text", "text": text]], "isError": isError]
    }

    private static func reply(id: Any, result: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "result": result])
    }

    private static func reply(id: Any, error: (code: Int, message: String)) -> Data? {
        try? JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "error": ["code": error.code, "message": error.message]])
    }
}
