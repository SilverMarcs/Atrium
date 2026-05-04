import Foundation
import Darwin

/// `openpty(3)` lives in libutil; libutil is part of libSystem on Darwin so it
/// links automatically. Swift's `Darwin` overlay doesn't surface it, so we
/// declare the symbol directly. This is the same dance Swift Package Manager
/// uses for libc primitives that aren't bridged.
@_silgen_name("openpty")
private func c_openpty(_ master: UnsafeMutablePointer<Int32>,
                       _ slave: UnsafeMutablePointer<Int32>,
                       _ name: UnsafeMutablePointer<CChar>?,
                       _ termp: UnsafePointer<termios>?,
                       _ winp: UnsafePointer<winsize>?) -> Int32

enum PTY {
    /// Allocates a pseudo-terminal pair sized to (rows × cols).
    ///
    /// `echo: false` disables the line discipline's local echo — Atrium's input
    /// bar already paints typed lines into the output view, so leaving ECHO on
    /// would print every submitted line twice.
    static func open(rows: UInt16 = 40,
                     cols: UInt16 = 120,
                     echo: Bool = false) -> (master: Int32, slave: Int32)? {
        var master: Int32 = -1
        var slave: Int32 = -1
        var ws = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)

        let rc = withUnsafePointer(to: &ws) { wsPtr in
            c_openpty(&master, &slave, nil, nil, wsPtr)
        }
        guard rc == 0 else { return nil }

        if !echo {
            var t = termios()
            if tcgetattr(slave, &t) == 0 {
                t.c_lflag &= ~tcflag_t(ECHO | ECHOE | ECHOK | ECHONL)
                _ = tcsetattr(slave, TCSANOW, &t)
            }
        }

        return (master, slave)
    }
}
