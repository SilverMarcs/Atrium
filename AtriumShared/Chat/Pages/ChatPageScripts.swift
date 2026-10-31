import Foundation

/// What every page an agent shows runs before its own content: the theme and
/// classes the `render_html` tool describes to agents, what makes its tabs and
/// tooltips work, and a report of the page's height.
enum ChatPageScripts {
    static let heightMessage = "atriumPageHeight"

    /// Atrium's green leads; the other series hues sit beside it without competing.
    private static let variables = """
        :root{color-scheme:light dark;accent-color:var(--primary);--radius:10px;
        --font-sans:-apple-system,BlinkMacSystemFont,system-ui,sans-serif;
        --font-mono:ui-monospace,"SF Mono",Menlo,monospace;
        --background:#ffffff;--foreground:#1d1d1f;--muted-foreground:#6e6e73;--popover:#ffffff;
        --primary:#4bb451;--primary-foreground:#ffffff;--accent-foreground:#2f8a35;
        --success:#34c759;--warning:#ff9500;--destructive:#ff3b30;
        --viz-series-2:#ef8a3e;--viz-series-3:#1aa39a;--viz-series-4:#e0679f;--viz-series-5:#8b6fe0;--viz-series-6:#3b8fe0}
        @media (prefers-color-scheme:dark){:root{
        --background:#1c1c1e;--foreground:#f5f5f7;--muted-foreground:#98989d;--popover:#2c2c2e;
        --primary:#5cc762;--accent-foreground:#8fdc93;
        --success:#30d158;--warning:#ff9f0a;--destructive:#ff453a;
        --viz-series-2:#f5a05a;--viz-series-3:#3cc6bc;--viz-series-4:#ee8dbb;--viz-series-5:#a993f0;--viz-series-6:#64a8ef}}
        :root{--card:color-mix(in srgb,var(--foreground) 5%,transparent);--card-foreground:var(--foreground);
        --muted:color-mix(in srgb,var(--foreground) 8%,transparent);
        --border:color-mix(in srgb,var(--foreground) 12%,transparent);
        --accent:color-mix(in srgb,var(--primary) 14%,transparent);
        --popover-foreground:var(--foreground);--viz-series-1:var(--primary)}
        """

    /// Goes in first, so the page's own styles win over it.
    private static let components = """
        html{font:-apple-system-body;font-family:var(--font-sans);color:var(--foreground);
        background:transparent;-webkit-text-size-adjust:100%;padding:4px 0}
        body{margin:0}code,kbd,pre,samp{font-family:var(--font-mono)}
        h1,h2,h3{font-weight:500;line-height:1.3;margin:0 0 .5em}h1{font-size:1.4em}h2{font-size:1.2em}h3{font-size:1.05em}
        p{margin:0 0 .75em}a{color:var(--accent-foreground)}b,strong,th{font-weight:500}
        .card{background:var(--card);color:var(--card-foreground);border-radius:var(--radius);padding:16px}
        .grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(160px,1fr));gap:12px}
        .row{display:flex;flex-wrap:wrap;align-items:center;gap:8px}
        .stat-label,.muted{color:var(--muted-foreground)}.stat-label{font-size:.85em}
        .stat-value{font-size:1.6em;font-weight:500;line-height:1.2;margin-top:2px}
        .small{font-size:.85em}.num{text-align:right;font-variant-numeric:tabular-nums}
        table{width:100%;border-collapse:collapse}
        th,td{text-align:left;padding:8px 10px;border-bottom:1px solid var(--border)}
        th{color:var(--muted-foreground);font-size:.85em}tbody tr:last-child td{border-bottom:0}
        .btn{font:inherit;color:var(--foreground);background:var(--muted);border:0;border-radius:999px;padding:5px 14px}
        .btn-primary,.btn[aria-pressed=true]{background:var(--primary);color:var(--primary-foreground)}
        .tabs{display:inline-flex;gap:2px;padding:2px;margin-bottom:12px;background:var(--muted);border-radius:999px}
        .tabs [role=tab]{font:inherit;font-size:.9em;color:var(--muted-foreground);background:none;border:0;border-radius:999px;padding:4px 14px}
        .tabs [role=tab][aria-selected=true]{color:var(--foreground);background:var(--popover);box-shadow:0 1px 2px rgb(0 0 0/.12)}
        [role=tabpanel][hidden]{display:none}
        .atrium-tooltip{position:fixed;z-index:100;pointer-events:none;max-width:240px;padding:4px 8px;
        font-size:.85em;color:var(--popover-foreground);background:var(--popover);border-radius:6px;
        box-shadow:0 2px 8px rgb(0 0 0/.18)}
        """

    /// Tabs switch their panels and `data-tooltip` shows on hover or tap,
    /// so pages need no script of their own for either.
    private static let behaviors = """
        document.addEventListener("click",function(e){
        var tab=e.target.closest&&e.target.closest("[role=tab]"),list=tab&&tab.closest("[role=tablist]");if(!list)return;
        list.querySelectorAll("[role=tab]").forEach(function(t){var on=t===tab,p=document.getElementById(t.getAttribute("aria-controls"));
        t.setAttribute("aria-selected",on);if(p)p.hidden=!on;});});
        var tip;function hide(){if(tip)tip.remove();tip=null;}
        function show(e){var el=e.target.closest&&e.target.closest("[data-tooltip]");if(!el){hide();return;}
        if(!tip){tip=document.createElement("div");tip.className="atrium-tooltip";tip.setAttribute("role","tooltip");document.body.append(tip);}
        tip.textContent=el.getAttribute("data-tooltip");var w=tip.offsetWidth,h=tip.offsetHeight;
        tip.style.left=Math.max(4,Math.min(innerWidth-w-4,e.clientX-w/2))+"px";
        tip.style.top=(e.clientY-h-10<4?e.clientY+16:e.clientY-h-10)+"px";}
        document.addEventListener("pointermove",show);document.addEventListener("pointerdown",show);
        document.documentElement.addEventListener("pointerleave",hide);
        """

    static let theme = """
        (function(){\
        var v=document.createElement("meta");v.name="viewport";v.content="width=device-width,initial-scale=1";\
        var s=document.createElement("style");s.textContent=\(String(reflecting: variables + components));\
        document.documentElement.append(v,s);\(behaviors)})();
        """

    /// A sheet gives the page the side margins it leaves out inline, inside
    /// the page so they scroll with it, and keeps it from squeezing below about
    /// the narrowest reply width it was written for; on iPhone it overflows
    /// instead, and scrolls both ways. Runs after `theme`, so it wins over it.
    static let sheet = """
        (function(){var s=document.createElement("style");s.textContent="html{min-width:600px;padding-inline:16px}";\
        document.documentElement.append(s);})();
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
