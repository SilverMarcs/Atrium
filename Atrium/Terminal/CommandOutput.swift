import Foundation
import Observation

/// Append-only buffer of command output. ANSI escape sequences are stripped
/// and `\r` (without `\n`) rewinds to the start of the current line so
/// spinners and progress bars overwrite in place.
@Observable
final class CommandOutput {
    /// Soft cap on retained text. When exceeded we drop oldest output to the
    /// next line boundary, keeping ~`trimTarget` bytes. Prevents `man bash`
    /// or `tail -f` from growing the buffer unboundedly and choking SwiftUI's
    /// Text rendering.
    private let maxLength = 256 * 1024
    private let trimTarget = 192 * 1024

    private(set) var text: String = ""

    func append(_ chunk: String) {
        guard !chunk.isEmpty else { return }
        let cleaned = ANSIStripper.strip(chunk)

        // Build the new text in a local buffer so the @Observable property
        // gets exactly one write per chunk — not one per character. Without
        // this, large dumps (e.g. `man bash`) trigger hundreds of thousands
        // of observation notifications and freeze the UI.
        var buf = text
        // Per-char loop is fine — we mutate the local `buf`, not the
        // @Observable `text`, so there's only one notification per chunk.
        for ch in cleaned {
            switch ch {
            case "\r":
                // CR alone — rewind to the start of the current line.
                if let lastNewline = buf.lastIndex(of: "\n") {
                    buf.removeSubrange(buf.index(after: lastNewline)..<buf.endIndex)
                } else {
                    buf.removeAll(keepingCapacity: true)
                }
            case "\u{08}":
                // BS — drop the previous char. Handles `man`'s overstrike
                // bold/underline encoding (`B\bB` -> `B`, `_\bX` -> `X`).
                if let last = buf.last, last != "\n" {
                    buf.removeLast()
                }
            default:
                buf.append(ch)
            }
        }

        if buf.count > maxLength {
            let dropCount = buf.count - trimTarget
            let dropEnd = buf.index(buf.startIndex, offsetBy: dropCount)
            // Snap to the next newline so we never slice mid-line.
            let snapped = buf[dropEnd...].firstIndex(of: "\n").map { buf.index(after: $0) } ?? dropEnd
            buf.removeSubrange(buf.startIndex..<snapped)
            buf.insert(contentsOf: "[…earlier output trimmed…]\n", at: buf.startIndex)
        }

        text = buf
    }

    func clear() {
        text.removeAll(keepingCapacity: false)
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
                    while let c = iter.next() {
                        let v = c.value
                        if v >= 0x40 && v <= 0x7E { break }
                    }
                case "]":
                    while let c = iter.next() {
                        if c == "\u{07}" { break }
                        if c == "\u{1B}" {
                            _ = iter.next()
                            break
                        }
                    }
                default:
                    break
                }
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }
}
