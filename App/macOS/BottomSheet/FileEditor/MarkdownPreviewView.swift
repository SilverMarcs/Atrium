import SwiftUI
import WebKit

/// A Markdown preview rendered via WKWebView.
///
/// Converts raw Markdown text to styled HTML using an embedded JavaScript
/// parser (marked.js) with syntax-highlighted code blocks (highlight.js).
/// Automatically adapts to light and dark color schemes, drawing a transparent background.
struct MarkdownPreviewView: NSViewRepresentable {
    let markdownText: String
    let fontSize: CGFloat

    @Environment(\.colorScheme) private var colorScheme

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let isDark = colorScheme == .dark
        let html = Self.buildHTML(markdown: markdownText, fontSize: fontSize, isDark: isDark)
        webView.loadHTMLString(html, baseURL: nil)
    }

    // MARK: - HTML Generation

    private static func buildHTML(markdown: String, fontSize: CGFloat, isDark: Bool) -> String {
        let escapedMarkdown = markdown
            .replacing("\\", with: "\\\\")
            .replacing("`", with: "\\`")
            .replacing("$", with: "\\$")

        let textColor = isDark ? "#d4d4d4" : "#1e1e1e"
        let codeBackground = isDark ? "#2d2d2d" : "#f5f5f5"
        let codeBorderColor = isDark ? "#404040" : "#e0e0e0"
        let inlineCodeBackground = isDark ? "#383838" : "#ebebeb"
        let linkColor = isDark ? "#4daafc" : "#0969da"
        let hrColor = isDark ? "#404040" : "#d1d5db"
        let blockquoteBorder = isDark ? "#505050" : "#d0d7de"
        let blockquoteText = isDark ? "#8b949e" : "#656d76"
        let tableHeaderBg = isDark ? "#2d2d2d" : "#f6f8fa"
        let tableBorder = isDark ? "#404040" : "#d0d7de"
        let hlTheme = isDark ? "atom-one-dark" : "atom-one-light"

        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/styles/\(hlTheme).min.css">
        <style>
            * { box-sizing: border-box; margin: 0; padding: 0; }
            body {
                font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", sans-serif;
                font-size: \(fontSize)px;
                line-height: 1.6;
                color: \(textColor);
                background-color: transparent;
                padding: 16px 20px;
                -webkit-font-smoothing: antialiased;
            }
            h1, h2, h3, h4, h5, h6 {
                margin-top: 1.2em;
                margin-bottom: 0.6em;
                font-weight: 600;
                line-height: 1.25;
            }
            h1 { font-size: 1.8em; border-bottom: 1px solid \(hrColor); padding-bottom: 0.3em; }
            h2 { font-size: 1.5em; border-bottom: 1px solid \(hrColor); padding-bottom: 0.3em; }
            h3 { font-size: 1.25em; }
            h4 { font-size: 1.1em; }
            p { margin-bottom: 0.8em; }
            a { color: \(linkColor); text-decoration: none; }
            a:hover { text-decoration: underline; }
            code {
                font-family: "SF Mono", SFMono-Regular, Menlo, Monaco, monospace;
                font-size: 0.9em;
                background: \(inlineCodeBackground);
                padding: 0.15em 0.4em;
                border-radius: 4px;
            }
            pre {
                margin: 0.8em 0;
                padding: 12px 16px;
                background: \(codeBackground);
                border: 1px solid \(codeBorderColor);
                border-radius: 8px;
                overflow-x: auto;
                line-height: 1.5;
            }
            pre code {
                background: transparent;
                padding: 0;
                border-radius: 0;
                font-size: 0.88em;
            }
            blockquote {
                margin: 0.8em 0;
                padding: 0.2em 1em;
                border-left: 3px solid \(blockquoteBorder);
                color: \(blockquoteText);
            }
            ul, ol { margin: 0.5em 0; padding-left: 1.8em; }
            li { margin-bottom: 0.3em; }
            hr {
                border: none;
                border-top: 1px solid \(hrColor);
                margin: 1.5em 0;
            }
            table {
                border-collapse: collapse;
                margin: 0.8em 0;
                width: 100%;
            }
            th, td {
                border: 1px solid \(tableBorder);
                padding: 6px 12px;
                text-align: left;
            }
            th {
                background: \(tableHeaderBg);
                font-weight: 600;
            }
            img {
                max-width: 100%;
                height: auto;
                border-radius: 6px;
            }
            ::-webkit-scrollbar { width: 8px; height: 8px; }
            ::-webkit-scrollbar-track { background: transparent; }
            ::-webkit-scrollbar-thumb {
                background: \(isDark ? "#555" : "#ccc");
                border-radius: 4px;
            }
        </style>
        </head>
        <body>
        <div id="content"></div>
        <script src="https://cdnjs.cloudflare.com/ajax/libs/marked/12.0.2/marked.min.js"></script>
        <script src="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/highlight.min.js"></script>
        <script>
            marked.setOptions({
                highlight: function(code, lang) {
                    if (lang && hljs.getLanguage(lang)) {
                        return hljs.highlight(code, { language: lang }).value;
                    }
                    return hljs.highlightAuto(code).value;
                },
                breaks: true,
                gfm: true
            });
            const md = `\(escapedMarkdown)`;
            document.getElementById('content').innerHTML = marked.parse(md);
        </script>
        </body>
        </html>
        """
    }
}
