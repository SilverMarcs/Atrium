import AppKit
import AtriumProtocol
import Foundation
import SwiftUI
import WebKit

/// Exercises the real host service and WebKit handler without starting a host or relay.
@MainActor
final class AgentIntegrationStore {
    var threads: [AgentThread] = []
    let media = TranscriptMedia()
    var messages: [TranscriptMessage] = []
    var reads = 0

    func transcript(for thread: AgentThread) async throws -> [TranscriptMessage] {
        reads += 1
        media.record(messages, of: thread)
        return messages
    }

    func promptImage(_ index: Int, of messageID: String, in thread: AgentThread) async -> Data? { nil }
}

nonisolated struct ChatMedia: Sendable {
    let service: MediaService
    let taskID: String
    let directory: String

    func image(atPath path: String, maxPixelSize: Int, pageKey: String? = nil) async -> Data? {
        guard case .image(let data) = await service.image(path, maxPixelSize: maxPixelSize,
                                                        inTask: taskID, pageKey: pageKey) else { return nil }
        return data
    }
}

@main
struct PageMediaChecks {
    struct Failure: Error { let message: String }

    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do {
                try await run()
                print("Page media checks passed")
                app.terminate(nil)
            } catch {
                print("FAILED: \(error)")
                exit(1)
            }
        }
        app.run()
    }

    @MainActor static func run() async throws {
        let scratch = URL(filePath: CommandLine.arguments[1], directoryHint: .isDirectory)
        let project = scratch.appending(path: "project", directoryHint: .isDirectory)
        let assets = scratch.appending(path: "page assets", directoryHint: .isDirectory)
        let outside = scratch.appending(path: "page assets-other", directoryHint: .isDirectory)
        for folder in [project, assets, outside] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        guard let pixel = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=") else {
            throw Failure(message: "Invalid image fixture")
        }
        for url in [assets.appending(path: "one.png"), assets.appending(path: "two.png"),
                    project.appending(path: "local.png"), outside.appending(path: "secret.png"),
                    outside.appending(path: "another.png")] {
            try pixel.write(to: url)
        }
        try Data("This is not an image".utf8).write(to: assets.appending(path: "notes.txt"))
        try checkFilePages(in: scratch)
        try checkMarkdownImages()
        let escape = assets.appending(path: "escape.png")
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: escape.path(percentEncoded: false))) == nil {
            try FileManager.default.createSymbolicLink(at: escape, withDestinationURL: outside.appending(path: "secret.png"))
        }
        let base = assets.path(percentEncoded: false) + "/"
        let html = """
            <!doctype html><html><body><div id="pictures"></div><script>
            const base='\(base)';
            function show(){document.getElementById('pictures').innerHTML=
              ['one.png','two.png'].map(f=>`<img src="${base+f}?v=1">`).join('');}
            show();
            </script></body></html>
            """
        let integrations = AgentIntegrationStore()
        let thread = AgentThread(sessionID: "page-media", provider: .codex, title: "Page media",
                                 directory: project.path(percentEncoded: false), updatedAt: .now, status: .idle)
        integrations.threads = [thread]
        let blocks = ChatPages.blocks(inReply: "```atrium-page title=\"Test\"\n\(html)\n```", id: "reply")
        guard let page = blocks.first?.page, let key = page.key else { throw Failure(message: "Missing page") }
        integrations.messages = [.init(id: "reply", role: .assistant, blocks: blocks)]
        let service = MediaService(integrations: integrations)
        // Cold host: a page request establishes its scope from the transcript exactly once.
        guard case .page = await service.page(key, inTask: thread.id) else { throw Failure(message: "Missing HTML") }
        let image = assets.appending(path: "one.png").path(percentEncoded: false)
        try await expectImage(service, image, taskID: thread.id, key: key)
        try await expectImage(service, project.appending(path: "local.png").path(percentEncoded: false), taskID: thread.id, key: key)
        try await expectDenied(service, outside.appending(path: "secret.png").path(percentEncoded: false), taskID: thread.id, key: key)
        try await expectDenied(service, assets.appending(path: "escape.png").path(percentEncoded: false), taskID: thread.id, key: key)
        try await expectDenied(service, assets.appending(path: "notes.txt").path(percentEncoded: false), taskID: thread.id, key: key)
        try await expectDenied(service, base + "../page assets-other/secret.png", taskID: thread.id, key: key)
        try await expectDenied(service, image, taskID: thread.id, key: "different-page")
        try await expectDenied(service, image, taskID: "different-task", key: key)
        try await expectDenied(service, image, taskID: thread.id, key: nil)
        let reads = integrations.reads
        try await expectDenied(service, outside.appending(path: "secret.png").path(percentEncoded: false), taskID: thread.id, key: key)
        try check(integrations.reads == reads, "Denied files in a known page must not reread its transcript")

        // Page B cannot reuse page A's folder; explicitly shown files still work outside a folder scope.
        let otherHTML = "<script>const photo='\(outside.appending(path: "secret.png").path(percentEncoded: false))?v=1#preview';</script>"
        let otherBlocks = ChatPages.blocks(inReply: "```atrium-page\n\(otherHTML)\n```", id: "other")
        guard let otherKey = otherBlocks.first?.page?.key else { throw Failure(message: "Missing second page") }
        integrations.media.record([.init(id: "other", role: .assistant, blocks: otherBlocks)], of: thread)
        try await expectDenied(service, image, taskID: thread.id, key: otherKey)
        try await expectImage(service, outside.appending(path: "secret.png").path(percentEncoded: false), taskID: thread.id, key: otherKey)
        try await expectDenied(service, outside.appending(path: "another.png").path(percentEncoded: false), taskID: thread.id, key: otherKey)
        let home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
        let broad = PageImageScope(html: "<script>const root='/';const home='\(home)/';</script>",
                                   directory: thread.directory, imagePaths: [])
        try check(!broad.allows(canonicalPath: PageImageScope.canonicalPath(image)), "A page cannot grant the filesystem root")
        try check(!broad.allows(canonicalPath: PageImageScope.canonicalPath(home + "/private.png")), "A page cannot grant the home folder")
        // An extra page field is optional on the wire, preserving older companions.
        let old = Data(#"{"image":{"taskID":"task","path":"/tmp/image.png","maxPixelSize":2048}}"#.utf8)
        guard case .image(_, _, _, nil) = try JSONDecoder().decode(HostRequest.self, from: old) else {
            throw Failure(message: "Legacy image request must decode without a page key")
        }

        let media = ChatMedia(service: service, taskID: thread.id, directory: thread.directory)
        let files = ChatPageFiles(media: media, pageKey: key)
        var configuration = WebPage.Configuration()
        configuration.websiteDataStore = .nonPersistent()
        guard let scheme = URLScheme(ChatPageFiles.scheme) else { throw Failure(message: "Invalid scheme") }
        configuration.urlSchemeHandlers[scheme] = files
        let web = WebPage(configuration: configuration)
        web.load(html: html, baseURL: files.baseURL)
        try await Task.sleep(for: .seconds(2))
        let loaded = try await web.callJavaScript("return [...document.images].filter(i=>i.complete&&i.naturalWidth>0).length") as? Int
        try check(loaded == 2, "JavaScript-built image paths with query strings must load in WebKit")
        _ = try await web.callJavaScript("show()")
        try await Task.sleep(for: .milliseconds(200))
        let reloaded = try await web.callJavaScript("return [...document.images].filter(i=>i.complete&&i.naturalWidth>0).length") as? Int
        try check(reloaded == 2, "Replacing page content must keep image loading working")
        integrations.media.forget(thread.id)
        try check(!integrations.media.shows(page: key, in: thread.id), "Forgetting a task removes its page scopes")
        try await expectImage(service, image, taskID: thread.id, key: key)
        if let fixture = ProcessInfo.processInfo.environment["ATRIUM_PAGE_FIXTURE"] {
            try await checkExistingPage(at: fixture, media: media, integrations: integrations, thread: thread)
        }
    }

    @MainActor static func checkExistingPage(at path: String, media: ChatMedia,
                                             integrations: AgentIntegrationStore, thread: AgentThread) async throws {
        let html = try String(contentsOfFile: path, encoding: .utf8)
        let blocks = ChatPages.blocks(inReply: "```atrium-page\n\(html)\n```", id: "fixture")
        guard let key = blocks.first?.page?.key else { throw Failure(message: "Missing fixture page") }
        integrations.media.record([.init(id: "fixture", role: .assistant, blocks: blocks)], of: thread)
        let files = ChatPageFiles(media: media, pageKey: key)
        var configuration = WebPage.Configuration()
        guard let scheme = URLScheme(ChatPageFiles.scheme) else { throw Failure(message: "Invalid fixture scheme") }
        configuration.urlSchemeHandlers[scheme] = files
        let web = WebPage(configuration: configuration)
        web.load(html: html, baseURL: files.baseURL)
        try await Task.sleep(for: .seconds(2))
        let result = try await web.callJavaScript("""
            return (async()=>{
              const platform=document.getElementById('fn-platform'),screen=document.getElementById('fn-screen');
              let checked=0,images=0,broken=0;
              for(const p of [...platform.options].map(o=>o.value)){
                platform.value=p;platform.dispatchEvent(new Event('change'));
                for(const id of [...screen.options].map(o=>o.value)){
                  for(const version of ['main','branch']){
                    document.querySelector('[data-version="'+version+'"]').click();
                    screen.value=id;screen.dispatchEvent(new Event('change'));
                    await Promise.all([...document.images].map(i=>i.complete?Promise.resolve():new Promise(r=>{
                      i.onload=r;i.onerror=r;setTimeout(r,1000);
                    })));
                    checked++;
                    for(const i of document.images){images++;if(!i.complete||!i.naturalWidth)broken++;}
                  }
                }
              }
              return {checked,images,broken};
            })()
            """) as? [String: Int]
        guard let result else { throw Failure(message: "Missing fixture result") }
        try check(result["broken"] == 0 && (result["images"] ?? 0) > 0, "Existing page must load all images: \(result)")
        print("Existing page: \(result)")
    }

    @MainActor static func expectImage(_ service: MediaService, _ path: String, taskID: String, key: String?) async throws {
        guard case .image = await service.image(path, maxPixelSize: 2048, inTask: taskID, pageKey: key) else {
            throw Failure(message: "Expected image: \(path)")
        }
    }

    @MainActor static func expectDenied(_ service: MediaService, _ path: String, taskID: String, key: String?) async throws {
        guard case .failed = await service.image(path, maxPixelSize: 2048, inTask: taskID, pageKey: key) else {
            throw Failure(message: "Expected denial: \(path)")
        }
    }

    /// A page shown from a file keeps the version each reply showed, after the
    /// file changes and after memory forgets it.
    static func checkFilePages(in scratch: URL) throws {
        ChatPages.copies = scratch.appending(path: "copies", directoryHint: .isDirectory)
        let file = scratch.appending(path: "diagram.html")
        let fence = "Intro\n```atrium-page title=\"Flow\" src=\"\(file.path(percentEncoded: false))\"\n```\nAfter"
        func shown(_ id: String) throws -> String {
            let blocks = ChatPages.blocks(inReply: fence, id: id)
            try check(blocks.first?.page?.title == "Flow", "File page keeps its title")
            try check(blocks.last?.text == "Intro\nAfter", "File page fence is taken out of the text")
            guard let key = blocks.first?.page?.key, let html = ChatPages.html(forKey: key) else {
                throw Failure(message: "File page has no HTML")
            }
            return html
        }
        try Data("<p>one</p>".utf8).write(to: file)
        try check(try shown("first") == "<p>one</p>", "First reply shows the file")
        try Data("<p>two</p>".utf8).write(to: file)
        try check(try shown("second") == "<p>two</p>", "Second reply shows the edited file")
        try check(try shown("first") == "<p>one</p>", "First reply keeps its copy after the file changes")
        try FileManager.default.removeItem(at: file)
        try check(try shown("second") == "<p>two</p>", "A copy outlives the file")
        try check(try shown("third").contains("is gone"), "A reply whose file is missing says so")
    }

    /// Markdown image paths, including ones with spaces written without angle brackets.
    static func checkMarkdownImages() throws {
        let markdown = """
            **Caption:** see below.
            ![a](/Users/me/Atrium Screenshots/a (2).png)
            ![b](</tmp/b c.png> "Title") ![c](/tmp/c d.png)
            Inline ![d](/tmp/d.png) and ![e](/tmp/e f.png) in a sentence.
            ![f](/tmp/f(1).png)
            """
        try check(MediaSource.markdownImages(in: markdown)
            == ["/Users/me/Atrium Screenshots/a (2).png", "/tmp/b c.png", "/tmp/c d.png", "/tmp/d.png", "/tmp/f(1).png"],
            "Markdown image paths: \(MediaSource.markdownImages(in: markdown))")
    }

    static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }
}
