import Foundation

/// Splits the harness API's NDJSON stream into complete frames.
nonisolated struct JcodeFrameDecoder {
    enum Failure: Error { case oversizedFrame }

    private var buffer = Data()
    private let maximumFrameSize: Int

    // Histories embed base64 images and can exceed 32 MiB. Keep a bounded
    // 64 MiB budget, matching the harness bridge's frame limit.
    init(maximumFrameSize: Int = 64 * 1024 * 1024) {
        self.maximumFrameSize = maximumFrameSize
    }

    mutating func append(_ data: Data) throws -> [Data] {
        var frames: [Data] = []
        var start = data.startIndex
        // Search only the newly received bytes, not the entire accumulated
        // history on every read. Limits apply to frames, not network chunks.
        while let end = data[start...].firstIndex(of: 10) {
            try appendFragment(data[start..<end])
            frames.append(buffer)
            buffer = Data()
            start = data.index(after: end)
        }
        try appendFragment(data[start...])
        return frames
    }

    private mutating func appendFragment(_ fragment: Data) throws {
        guard fragment.count <= maximumFrameSize - buffer.count else {
            throw Failure.oversizedFrame
        }
        buffer.append(fragment)
    }
}
