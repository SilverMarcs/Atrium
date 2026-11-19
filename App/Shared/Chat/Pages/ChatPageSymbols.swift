import Foundation
import WebKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// SF Symbols for pages: `<i data-symbol="chart.bar.fill"></i>` asks for one
/// at `atrium-symbol:chart.bar.fill`, answered with the symbol drawn opaque on
/// clear, which the page's styles use as a mask in the text's own color.
nonisolated struct ChatPageSymbols: URLSchemeHandler {
    static let scheme = "atrium-symbol"
    /// Drawn this large, the symbol stays sharp up to about a 64-point icon.
    private static let pointSize: CGFloat = 64

    func reply(for request: URLRequest) -> AsyncThrowingStream<URLSchemeTaskResult, any Error> {
        AsyncThrowingStream { continuation in
            guard let url = request.url, let name = url.absoluteString.split(separator: ":", maxSplits: 1).last?.removingPercentEncoding,
                  let data = Self.png(named: name) else {
                continuation.finish(throwing: URLError(.fileDoesNotExist))
                return
            }
            // Masks load like fonts, so another scheme's page may use them only when allowed to.
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: [
                "Content-Type": "image/png", "Access-Control-Allow-Origin": "*",
            ]) ?? URLResponse(url: url, mimeType: "image/png", expectedContentLength: data.count, textEncodingName: nil)
            continuation.yield(.response(response))
            continuation.yield(.data(data))
            continuation.finish()
        }
    }

    private static func png(named name: String) -> Data? {
        #if os(macOS)
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return nil }
        let size = symbol.size
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        bitmap.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        symbol.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:])
        #else
        let configuration = UIImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        guard let symbol = UIImage(systemName: name, withConfiguration: configuration) else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        return UIGraphicsImageRenderer(size: symbol.size, format: format).pngData { _ in
            symbol.draw(at: .zero)
        }
        #endif
    }
}
