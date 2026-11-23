import Foundation

extension StringProtocol {
    /// The text's lines, split at each "\n" with any "\r" before it kept, so
    /// a patch rebuilt from them is byte for byte the same. Splitting on the
    /// Character "\n" misses CRLF endings: Swift reads "\r\n" as one Character.
    nonisolated var diffLines: [String] {
        utf8.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }
    }

    /// A diff line's text for display, without a CRLF file's "\r".
    nonisolated var withoutCarriageReturn: String {
        hasSuffix("\r") ? String(dropLast()) : String(self)
    }
}
