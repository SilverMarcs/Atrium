@testable import AtriumProtocol
import Foundation
import Testing

struct MediaSourceTests {
    @Test func sourcesAreWebOrHost() {
        #expect(MediaSource("https://example.com/a.png") == .web(URL(string: "https://example.com/a.png")!))
        #expect(MediaSource("//cdn.example.com/a.png") == .web(URL(string: "https://cdn.example.com/a.png")!))
        #expect(MediaSource("/tmp/shot.png") == .host(path: "/tmp/shot.png"))
        #expect(MediaSource("file:///tmp/a%20b.png") == .host(path: "/tmp/a b.png"))
        #expect(MediaSource("shots/a%20b.png") == .host(path: "shots/a b.png"))
        #expect(MediaSource("~/Desktop/a.png") == .host(path: "~/Desktop/a.png"))
        #expect(MediaSource("javascript:alert(1)") == nil)
        #expect(MediaSource("#top") == nil)
        #expect(MediaSource("  ") == nil)
    }

    @Test func markdownImagesAreFound() {
        let markdown = """
            Before ![chart](/tmp/chart.png) and ![two](</tmp/with space.png> "Title").
            [not an image](/tmp/link.png) ![escaped \\] alt](https://example.com/x.png)
            """
        #expect(MediaSource.markdownImages(in: markdown) == ["/tmp/chart.png", "/tmp/with space.png", "https://example.com/x.png"])
    }

    @Test func markdownImagesRoundTrip() {
        let markdown = MediaSource.markdownImage(path: "/tmp/odd <name> [1].png", alt: "a [b]")
        #expect(MediaSource.markdownImages(in: markdown) == ["/tmp/odd <name> [1].png"])
    }

    @Test func htmlImagesAreFound() {
        let html = """
            <img src="/tmp/a.png"><img alt='x' src='b.png' srcset="c.png 1x, /d/e.png 2x">
            <video poster="f.jpg"></video><div style="background: url('/g.png')"></div>
            <a href="/not-an-image.png">x</a><img src="https://x.com/i.png?a=1&amp;b=2">
            <script>canvas.toDataURL('image/png'); new URL(location.href); URL.createObjectURL(blob)</script>
            """
        #expect(MediaSource.htmlImages(in: html) == ["/tmp/a.png", "b.png", "c.png", "/d/e.png", "f.jpg", "https://x.com/i.png?a=1&b=2", "/g.png"])
    }

    @Test func htmlImagesAreReplacedInPlace() {
        let html = """
            <img src="a.png" alt="data.png"><img srcset="a.png 1x, /b.png 2x">
            <p>a.png</p><div style="background:url( 'a.png' )"></div><img src="https://x.com/a.png">
            """
        let replaced = MediaSource.replacingHTMLImages(in: html) { $0 == "a.png" ? "data:x" : nil }
        #expect(replaced == """
            <img src="data:x" alt="data.png"><img srcset="data:x 1x, /b.png 2x">
            <p>a.png</p><div style="background:url( 'data:x' )"></div><img src="https://x.com/a.png">
            """)
    }
}
