import Foundation
import ImageIO
import UniformTypeIdentifiers

extension UTType {
    /// The format of encoded image data that Image I/O decodes, read from its bytes.
    nonisolated init?(imageData data: Data) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let identifier = CGImageSourceGetType(source) as String? else { return nil }
        self.init(identifier)
    }
}
