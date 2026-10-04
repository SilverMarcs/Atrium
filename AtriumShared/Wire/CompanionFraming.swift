import Foundation

public enum CompanionFraming {
    public static func encode(_ message: CompanionMessage) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let body = try encoder.encode(message)
        precondition(body.count <= CompanionWire.maxFrameBytes, "frame too large")
        var prefix = UInt32(body.count).bigEndian
        var out = Data(capacity: 4 + body.count)
        withUnsafeBytes(of: &prefix) { out.append(contentsOf: $0) }
        out.append(body)
        return out
    }

    public static func decode(_ data: Data) throws -> CompanionMessage {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(CompanionMessage.self, from: data)
    }
}

public final class CompanionFrameBuffer {
    private var buffer = Data()

    public init() {}

    public func append(_ data: Data) {
        buffer.append(data)
    }

    public func nextFrame() throws -> Data? {
        guard buffer.count >= 4 else { return nil }
        let length = buffer.prefix(4).withUnsafeBytes { raw -> UInt32 in
            raw.load(as: UInt32.self).bigEndian
        }
        if Int(length) > CompanionWire.maxFrameBytes {
            throw CompanionFramingError.oversizedFrame(Int(length))
        }
        guard buffer.count >= 4 + Int(length) else { return nil }
        let body = buffer.subdata(in: 4 ..< 4 + Int(length))
        buffer.removeSubrange(0 ..< 4 + Int(length))
        return body
    }
}
