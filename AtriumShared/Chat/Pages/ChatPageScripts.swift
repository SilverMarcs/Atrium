import Foundation

/// What every page an agent shows runs before its own content: the theme the
/// `render_html` tool describes to agents, and a report of the page's height.
enum ChatPageScripts {
    static let heightMessage = "atriumPageHeight"

    /// Goes in first, so the page's own styles win over it.
    private static let css = """
        :root{color-scheme:light dark;--radius:10px;\
        --font-sans:-apple-system,BlinkMacSystemFont,system-ui,sans-serif;\
        --font-mono:ui-monospace,"SF Mono",Menlo,monospace;\
        --background:#ffffff;--foreground:#1d1d1f;--muted-foreground:#6e6e73;--card:#f2f2f7;\
        --border:rgba(60,60,67,.18);--accent:#4bb451;--accent-foreground:#ffffff;\
        --success:#34c759;--warning:#ff9500;--destructive:#ff3b30;\
        --chart-1:#4bb451;--chart-2:#0d9488;--chart-3:#d97706;--chart-4:#9333ea;--chart-5:#e11d48}\
        @media (prefers-color-scheme:dark){:root{\
        --background:#1c1c1e;--foreground:#f5f5f7;--muted-foreground:#98989d;--card:#2c2c2e;\
        --border:rgba(235,235,245,.16);--accent:#5cc762;--accent-foreground:#0b1f0c;\
        --success:#30d158;--warning:#ff9f0a;--destructive:#ff453a;\
        --chart-1:#5cc762;--chart-2:#2dd4bf;--chart-3:#fbbf24;--chart-4:#c084fc;--chart-5:#fb7185}}\
        html{font:-apple-system-body;font-family:var(--font-sans);color:var(--foreground);\
        background:transparent;-webkit-text-size-adjust:100%;padding:4px 0}\
        body{margin:0}code,kbd,pre,samp{font-family:var(--font-mono)}
        """

    static let theme = """
        (function(){\
        var v=document.createElement("meta");v.name="viewport";v.content="width=device-width,initial-scale=1";\
        var s=document.createElement("style");s.textContent=\(String(reflecting: css));\
        document.documentElement.append(v,s);})();
        """

    /// Content sets a page's height, so the frame can fit it without scrolling inside.
    static let height = """
        (function(){var last=0;\
        function report(){var h=Math.ceil(document.documentElement.getBoundingClientRect().height);\
        if(h!==last){last=h;window.webkit.messageHandlers.\(heightMessage).postMessage(h);}}\
        var o=new ResizeObserver(report);o.observe(document.documentElement);\
        document.addEventListener("DOMContentLoaded",function(){if(document.body)o.observe(document.body);report();});\
        window.addEventListener("load",report);})();
        """
}
