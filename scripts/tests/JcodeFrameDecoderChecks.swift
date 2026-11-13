import Foundation

@main
enum JcodeFrameDecoderChecks {
    struct CheckFailure: Error { let message: String }

    static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw CheckFailure(message: message) }
    }

    static func main() throws {
        // The reported chat's history was 37,613,128 bytes. It is a valid
        // harness frame, but Atrium disconnected at its old 32 MiB limit.
        var large = JcodeFrameDecoder()
        let payload = Data(repeating: 120, count: 36 * 1024 * 1024)
        let chunkSize = 262_144
        for start in stride(from: 0, to: payload.count, by: chunkSize) {
            let frames = try large.append(payload[start..<min(start + chunkSize, payload.count)])
            try check(frames.isEmpty, "An incomplete history must not be emitted")
        }
        try check(try large.append(Data([10])) == [payload], "Large history must survive intact")

        var split = JcodeFrameDecoder(maximumFrameSize: 16)
        try check(try split.append(Data("{\"a\":".utf8)).isEmpty, "Wait for a whole frame")
        try check(try split.append(Data("1}\n{\"b\":2}\n{\"c\":".utf8)) == [Data("{\"a\":1}".utf8), Data("{\"b\":2}".utf8)], "Preserve coalesced frame order")
        try check(try split.append(Data("3}\n".utf8)) == [Data("{\"c\":3}".utf8)], "Preserve the remaining fragment")

        var combined = JcodeFrameDecoder(maximumFrameSize: 4)
        try check(try combined.append(Data("1234\n1234\n".utf8)) == [Data("1234".utf8), Data("1234".utf8)], "Apply the limit per frame, not per read")

        var boundary = JcodeFrameDecoder(maximumFrameSize: 4)
        try check(try boundary.append(Data("1234".utf8)).isEmpty, "An exact-limit fragment is valid")
        try check(try boundary.append(Data([10])) == [Data("1234".utf8)], "A delimiter must not count toward the limit")
        try check(try boundary.append(Data()).isEmpty, "An empty read adds no frames")

        var oversized = JcodeFrameDecoder(maximumFrameSize: 4)
        _ = try oversized.append(Data("1234".utf8))
        do {
            _ = try oversized.append(Data("5\n".utf8))
            throw CheckFailure(message: "An oversized fragmented frame must fail")
        } catch JcodeFrameDecoder.Failure.oversizedFrame {}

        var wholeOversized = JcodeFrameDecoder(maximumFrameSize: 4)
        do {
            _ = try wholeOversized.append(Data("12345\n".utf8))
            throw CheckFailure(message: "An oversized complete frame must fail")
        } catch JcodeFrameDecoder.Failure.oversizedFrame {}

        let unicode = Data("{\"text\":\"🦝你好\"}\n".utf8)
        var bytes = JcodeFrameDecoder()
        var frames: [Data] = []
        for byte in unicode { frames += try bytes.append(Data([byte])) }
        try check(frames == [Data(unicode.dropLast())], "UTF-8 can be split at any byte")
        print("Jcode frame decoder checks passed")
    }
}
