import AtriumProtocol
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

@main
nonisolated enum JcodeImageStoreChecks {
    struct CheckFailure: Error { let message: String }

    static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw CheckFailure(message: message) }
    }

    static func png(_ component: UInt8) throws -> Data {
        let pixels = Data([component, 80, 160, 255])
        guard let provider = CGDataProvider(data: pixels as CFData),
              let image = CGImage(width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { throw CheckFailure(message: "Create test pixels") }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)
        else { throw CheckFailure(message: "Create PNG encoder") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CheckFailure(message: "Encode PNG") }
        return output as Data
    }

    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "JcodeImageStoreChecks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appending(path: "cache with spaces [and] brackets")
        let data = try png(20)
        let payload: [String: Any] = ["data": data.base64EncodedString()]
        guard let markdown = JcodeImageStore.markdown(for: payload, directory: directory),
              let path = MediaSource.markdownImages(in: markdown).first else {
            throw CheckFailure(message: "Valid PNG must produce parseable Markdown")
        }
        let url = URL(filePath: path)
        try check(try Data(contentsOf: url) == data, "Preserve original bytes")
        try check(markdown.hasPrefix("![Tool image]"), "Use fallback label")
        try check(!markdown.contains("base64"), "Never inline base64")
        try check(url.deletingLastPathComponent().path == directory.path, "Keep files within cache")
        let digest = SHA256.hash(data: data).map { String(0x100 + Int($0), radix: 16).dropFirst() }.joined()
        try check(url.lastPathComponent == "\(digest).png", "Name must hash actual bytes and actual type")
        let modification = Date(timeIntervalSince1970: 1000)
        try FileManager.default.setAttributes([.modificationDate: modification], ofItemAtPath: path)
        try check(JcodeImageStore.markdown(for: payload, directory: directory) == markdown, "Reuse existing path")
        let persistedDate = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        try check(persistedDate == modification, "Reuse must not rewrite existing file")
        let restored: [String: Any] = ["data": Data(data).base64EncodedString(), "mime_type": "image/jpeg", "path": "../../escape.jpg"]
        try check(JcodeImageStore.markdown(for: restored, directory: URL(filePath: directory.path)) == markdown, "Fresh calls reuse persisted cache and ignore claimed type/path")
        let changed = try png(21)
        let changedMarkdown = JcodeImageStore.markdown(for: ["data": changed.base64EncodedString()], directory: directory)
        try check(changedMarkdown != nil && changedMarkdown != markdown, "Different bytes need different paths")
        let label = "../../escape](/bad)\n[image].jpg"
        let labeled = JcodeImageStore.markdown(for: ["data": data.base64EncodedString(), "label": label, "path": "/escape"], directory: directory)
        try check(labeled == MediaSource.markdownImage(path: path, alt: label), "Delegate unsafe label escaping to real MediaSource")
        try check(JcodeImageStore.markdown(for: ["data": data.base64EncodedString(), "label": " \n "], directory: directory) == markdown, "Blank labels fall back")
        for invalid: [String: Any] in [[:], ["data": 42], ["data": ""], ["data": "not base64!"],
                                      ["data": Data("not an image".utf8).base64EncodedString()],
                                      ["data": Data(data.prefix(24)).base64EncodedString()],
                                      ["data": String(repeating: "A", count: ((20 * 1024 * 1024 + 2) / 3) * 4 + 4)],
                                      ["data": Data(repeating: 0, count: 20 * 1024 * 1024 + 1).base64EncodedString()]] {
            try check(JcodeImageStore.markdown(for: invalid, directory: directory) == nil, "Reject malformed, empty, truncated or oversized images")
        }
        guard let remote = URL(string: "https://example.com/cache") else { throw CheckFailure(message: "Create remote URL") }
        try check(JcodeImageStore.markdown(for: payload, directory: remote) == nil, "Reject non-file cache")
        let blocker = root.appending(path: "not-a-directory")
        try Data([1]).write(to: blocker)
        try check(JcodeImageStore.markdown(for: payload, directory: blocker) == nil, "Handle filesystem failures")
        let corrupt = Data(repeating: 0, count: data.count)
        try corrupt.write(to: url)
        try check(JcodeImageStore.markdown(for: payload, directory: directory) == nil, "Reject mismatching cached bytes")
        try check(try Data(contentsOf: url) == corrupt, "Never overwrite different content")
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: blocker)
        try check(JcodeImageStore.markdown(for: payload, directory: directory) == nil, "Reject cache symlink")
        try check(try Data(contentsOf: blocker) == Data([1]), "Do not overwrite symlink target")
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        try check(!files.contains { $0.hasSuffix(".tmp") }, "Clean up unpublished files")
        try check(JcodeImageStore.defaultDirectory == HostStorage.directory.appending(path: "JcodeImages", directoryHint: .isDirectory), "Follow bundle-aware Application Support convention")
        print("Jcode image store checks passed")
    }
}
