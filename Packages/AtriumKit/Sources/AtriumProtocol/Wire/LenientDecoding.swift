import Foundation

extension KeyedDecodingContainer {
    /// The value for `key`, or `fallback` when it's missing or can't be read.
    /// Rows decode field by field this way, so a field another build added,
    /// removed or changed costs only that field, not the row or its message.
    nonisolated func lenient<T: Decodable>(_ key: Key, or fallback: T) -> T {
        (try? decodeIfPresent(T.self, forKey: key)) ?? fallback
    }
}

/// A list that leaves out the rows it can't read, rather than failing whole,
/// such as a task of a provider this build doesn't know.
public nonisolated struct LossyRows<Element: Decodable>: Decodable {
    public let values: [Element]

    public init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var values: [Element] = []
        while !container.isAtEnd {
            let entry = try container.superDecoder()
            if let value = try? Element(from: entry) { values.append(value) }
        }
        self.values = values
    }
}
