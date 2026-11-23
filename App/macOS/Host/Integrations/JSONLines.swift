import Darwin
import Foundation

/// The JSON Lines files agents save their sessions in. They grow to many
/// megabytes, so they're searched for markers without parsing every line, and
/// read again only for the lines appended since.
nonisolated enum JSONLines {
    /// What was found in the whole lines of a file read so far.
    struct Scan<State> {
        var state: State
        private let initial: State
        private var scanned = 0

        init(_ initial: State) {
            state = initial
            self.initial = initial
        }

        /// Reads the whole lines appended since the last read into `state`.
        /// A line still being written waits for the next read; a file that
        /// shrank, as one rewritten, is read again from its start.
        mutating func read(_ url: URL, size: Int, _ body: (Data, Range<Int>, inout State) throws -> Void) throws {
            if size < scanned { self = Self(initial) }
            guard scanned < size else { return }
            let data = try Data(contentsOf: url, options: .alwaysMapped)
            guard scanned < data.count, let end = data[scanned...].lastIndex(of: 10) else { return }
            try body(data, scanned..<end, &state)
            scanned = end + 1
        }
    }

    /// Calls `body` with each line among those in `range` that contains
    /// `marker`, in file order or newest first, until it returns false.
    /// `range` starts a line. Newest first, the range is searched a chunk at a
    /// time from its end, so finding a recent line doesn't read all of it.
    static func forEachLine(containing marker: String, in data: Data, _ range: Range<Int>, newestFirst: Bool,
                            _ body: (Range<Int>) -> Bool) {
        let marker = Array(marker.utf8)
        let chunk = newestFirst ? 1 << 20 : range.count
        var upper = range.upperBound
        var seen = range.upperBound
        while upper > range.lowerBound {
            let lower = max(range.lowerBound, upper - chunk)
            // A match can straddle the chunk's end; lines already passed to `body` are skipped.
            let window = lower..<min(range.upperBound, upper + marker.count - 1)
            var lines: [Range<Int>] = []
            data.withUnsafeBytes { buffer in
                guard let base = buffer.baseAddress else { return }
                var position = window.lowerBound
                while position < window.upperBound,
                      let match = memmem(base + position, window.upperBound - position, marker, marker.count) {
                    let offset = base.distance(to: UnsafeRawPointer(match))
                    let start = buffer[range.lowerBound..<offset].lastIndex(of: 10).map { $0 + 1 } ?? range.lowerBound
                    let end = buffer[offset..<range.upperBound].firstIndex(of: 10) ?? range.upperBound
                    position = end + 1
                    if start < seen { lines.append(start..<end) }
                }
            }
            for line in newestFirst ? lines.reversed() : lines {
                guard body(line) else { return }
            }
            seen = lines.first?.lowerBound ?? seen
            upper = lower
        }
    }

    /// Where the first or last `marker` among the bytes in `range` ends.
    static func position(of marker: String, in data: Data, _ range: Range<Int>, last: Bool = false) -> Int? {
        let marker = Array(marker.utf8)
        return data.withUnsafeBytes { buffer -> Int? in
            guard let base = buffer.baseAddress else { return nil }
            var found: Int?
            var position = range.lowerBound
            while position < range.upperBound,
                  let match = memmem(base + position, range.upperBound - position, marker, marker.count) {
                let end = base.distance(to: UnsafeRawPointer(match)) + marker.count
                found = end
                guard last else { break }
                position = end
            }
            return found
        }
    }

    /// The JSON string that the first or last `marker`, ending in the
    /// string's opening quote, introduces among the bytes in `range`. Only the
    /// string itself is decoded. Nil for an empty one.
    static func string(after marker: String, in data: Data, _ range: Range<Int>, last: Bool = false) -> String? {
        guard let start = position(of: marker, in: data, range, last: last) else { return nil }
        var escaped = false
        for index in start..<range.upperBound {
            let byte = data[index]
            if escaped { escaped = false }
            else if byte == UInt8(ascii: "\\") { escaped = true }
            else if byte == UInt8(ascii: "\"") {
                return (try? JSONDecoder().decode(String.self, from: data[(start - 1)...index])).flatMap { $0.isEmpty ? nil : $0 }
            }
        }
        return nil
    }
}
