import Foundation

/// Where an image an agent showed comes from, as written in its Markdown or
/// in a page's HTML. Host paths are fetched with `HostRequest.image`, which
/// resolves them on the host: absolute, `~/`, or relative to the task's directory.
public nonisolated enum MediaSource: Hashable, Sendable {
    /// An `http`, `https` or `data` URL, which loads as-is.
    case web(URL)
    /// A file on the task's host.
    case host(path: String)

    /// The source a Markdown image or HTML attribute names, or nil for one
    /// that can't load, such as an empty source, a fragment, or another scheme.
    public init?(_ source: String) {
        let source = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty, !source.hasPrefix("#"), !source.hasPrefix("?") else { return nil }
        let scheme = source.prefix { $0 != ":" && $0 != "/" }.lowercased()
        if source.dropFirst(scheme.count).hasPrefix(":") {
            switch scheme {
            case "http", "https", "data":
                guard let url = URL(string: source) else { return nil }
                self = .web(url)
            case "file":
                guard let url = URL(string: source), url.isFileURL, !url.path.isEmpty else { return nil }
                self = .host(path: url.path(percentEncoded: false))
            default:
                // A Windows drive letter is a path, not a scheme, but never one on a Mac.
                return nil
            }
        } else if source.hasPrefix("//") {
            guard let url = URL(string: "https:" + source) else { return nil }
            self = .web(url)
        } else {
            self = .host(path: source.removingPercentEncoding ?? source)
        }
    }

    /// The image sources in Markdown, such as `![chart](</tmp/a b.png>)`, in order.
    public static func markdownImages(in markdown: String) -> [String] {
        markdown.matches(of: markdownImage).map { match in
            let destination = String(match.output.1)
            return destination.hasPrefix("<") && destination.hasSuffix(">")
                ? String(destination.dropFirst().dropLast()).replacing("\\<", with: "<").replacing("\\>", with: ">")
                : destination
        }
    }

    /// The sources an HTML page loads images from: `src`, `srcset`, `poster`
    /// and CSS `url(…)`, in order. Entities like `&amp;` are decoded.
    public static func htmlImages(in html: String) -> [String] {
        htmlImageSources(in: html).map(\.source)
    }

    /// The HTML with each image source `htmlImages(in:)` finds replaced by what
    /// `transform` returns for it, or left as it is for nil. Replacements are
    /// written as they are, so they shouldn't hold quotes, spaces or entities.
    public static func replacingHTMLImages(in html: String, _ transform: (String) -> String?) -> String {
        var html = html
        var end = html.endIndex
        // Back to front, so the ranges still ahead stay valid.
        for (range, source) in htmlImageSources(in: html).sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            guard range.upperBound <= end else { continue }
            end = range.lowerBound
            if let replacement = transform(source) { html.replaceSubrange(range, with: replacement) }
        }
        return html
    }

    private static func htmlImageSources(in html: String) -> [(range: Range<String.Index>, source: String)] {
        var sources: [(range: Range<String.Index>, source: String)] = []
        for match in html.matches(of: htmlAttribute) {
            guard let value = match.output.2 ?? match.output.3 else { continue }
            if match.output.1.lowercased() == "srcset" {
                for candidate in value.split(separator: ",") {
                    if let url = candidate.split(whereSeparator: \.isWhitespace).first {
                        sources.append((url.startIndex..<url.endIndex, decodingEntities(String(url))))
                    }
                }
            } else {
                let value = trimmingWhitespace(value)
                sources.append((value.startIndex..<value.endIndex, decodingEntities(String(value))))
            }
        }
        for match in html.matches(of: cssURL) {
            let value = trimmingWhitespace(match.output.1)
            sources.append((value.startIndex..<value.endIndex, String(value)))
        }
        return sources.filter { !$0.source.isEmpty }
    }

    private static func trimmingWhitespace(_ value: Substring) -> Substring {
        let start = value.firstIndex { !$0.isWhitespace } ?? value.endIndex
        let end = value.lastIndex { !$0.isWhitespace }.map(value.index(after:)) ?? start
        return value[start..<max(start, end)]
    }

    /// Writes a host path as a Markdown image destination, safe for spaces and brackets.
    public static func markdownImage(path: String, alt: String = "") -> String {
        let alt = alt.replacing("[", with: "\\[").replacing("]", with: "\\]").replacing("\n", with: " ")
        let destination = path.replacing("<", with: "\\<").replacing(">", with: "\\>").replacing("\n", with: "")
        return "![\(alt)](<\(destination)>)"
    }

    private static func decodingEntities(_ value: String) -> String {
        guard value.contains("&") else { return value }
        return value.replacing("&quot;", with: "\"").replacing("&#39;", with: "'").replacing("&apos;", with: "'")
            .replacing("&lt;", with: "<").replacing("&gt;", with: ">").replacing("&amp;", with: "&")
    }

    // `![alt](destination "title")`, where the destination may be wrapped in angle brackets.
    nonisolated(unsafe) private static let markdownImage = #/!\[(?:[^\]\\]|\\.)*\]\(\s*(<(?:[^>\\\n]|\\.)*>|[^\s)]+)(?:\s+(?:"[^"]*"|'[^']*'))?\s*\)/#
    nonisolated(unsafe) private static let htmlAttribute = #/(?i)\s(src|srcset|poster)\s*=\s*(?:"([^"]*)"|'([^']*)')/#
    // `url(` that isn't part of a longer name, so script calls like `toDataURL(…)` don't count.
    nonisolated(unsafe) private static let cssURL = #/(?:^|[^\w.$])url\(\s*["']?([^"')]+)["']?\s*\)/#
}
