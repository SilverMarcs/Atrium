import Foundation
import Observation

/// Append-only buffer of command output. The view layer observes `version`
/// to know when to pull the latest delta via `drainPending()`.
@Observable
final class CommandOutput {
    /// Bumped after every append/clear so SwiftUI redraws (cheap Int change
    /// rather than republishing the whole text storage).
    private(set) var version: Int = 0

    @ObservationIgnored
    private(set) var fullText: String = ""

    /// Text appended since the last `drainPending()` call. Lets the NSTextView
    /// representable do incremental appends without rebuilding the document.
    @ObservationIgnored
    private var pending: String = ""

    /// Tracks whether the last byte of `fullText` is a partial line waiting
    /// for either `\n` (commit) or `\r` (overwrite). `\r` collapse rewinds
    /// `fullText` back to the start of the current line so spinners and
    /// progress bars don't print a wall of duplicate lines.
    @ObservationIgnored
    private var currentLineStart: String.Index

    init() {
        currentLineStart = "".endIndex
    }

    func append(_ chunk: String) {
        guard !chunk.isEmpty else { return }
        let cleaned = ANSIStripper.strip(chunk)
        for ch in cleaned {
            switch ch {
            case "\r":
                // CR without LR — drop everything since the start of the
                // current line so the next characters overwrite it.
                let removed = String(fullText[currentLineStart...])
                fullText.removeSubrange(currentLineStart..<fullText.endIndex)
                if !removed.isEmpty {
                    pending.append("\u{1B}[REWIND:\(removed.count)]")
                }
            case "\n":
                fullText.append(ch)
                pending.append(ch)
                currentLineStart = fullText.endIndex
            default:
                fullText.append(ch)
                pending.append(ch)
            }
        }
        version &+= 1
    }

    /// Returns and clears the buffer of text-deltas the view hasn't applied
    /// yet. Encodes CR-rewinds as `ESC[REWIND:n]` so the text view can pop
    /// `n` characters before appending the next chunk.
    func drainPending() -> String {
        defer { pending.removeAll(keepingCapacity: true) }
        return pending
    }

    func clear() {
        fullText.removeAll(keepingCapacity: false)
        pending.removeAll(keepingCapacity: false)
        currentLineStart = fullText.endIndex
        // Sentinel "\u{1B}[CLEAR]" tells the view to wipe its storage.
        pending = "\u{1B}[CLEAR]"
        version &+= 1
    }
}

/// Strips ANSI CSI/OSC sequences so the text view sees only printable
/// characters. We intentionally lose color since Tier A is plain-text only.
enum ANSIStripper {
    static func strip(_ s: String) -> String {
        guard s.contains("\u{1B}") else { return s }
        var out = String()
        out.reserveCapacity(s.count)
        var iter = s.unicodeScalars.makeIterator()
        while let scalar = iter.next() {
            if scalar == "\u{1B}" {
                guard let next = iter.next() else { break }
                switch next {
                case "[":
                    // CSI: skip until a final byte in 0x40-0x7E
                    while let c = iter.next() {
                        let v = c.value
                        if v >= 0x40 && v <= 0x7E { break }
                    }
                case "]":
                    // OSC: skip until BEL or ESC \
                    while let c = iter.next() {
                        if c == "\u{07}" { break }
                        if c == "\u{1B}" {
                            _ = iter.next()  // consume the trailing '\\'
                            break
                        }
                    }
                default:
                    // Other 2-char escape (e.g. ESC =, ESC >) — drop both bytes.
                    break
                }
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }
}
