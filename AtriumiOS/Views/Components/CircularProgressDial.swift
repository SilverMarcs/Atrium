import SwiftUI

/// Determinate circular progress indicator. SwiftUI's
/// `ProgressView(value:).progressViewStyle(.circular)` is indeterminate on
/// iOS (it spins regardless of `value`), so we draw the ring ourselves —
/// background track + trimmed accent stroke that fills clockwise from 12
/// o'clock as `progress` moves from 0 to 1.
struct CircularProgressDial: View {
    let progress: Double

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.accentColor.opacity(0.2), lineWidth: 3)
            Circle()
                .trim(from: 0, to: clamped)
                .stroke(
                    Color.accentColor,
                    style: StrokeStyle(lineWidth: 3, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.25), value: clamped)
        }
    }

    private var clamped: Double {
        min(1, max(0, progress))
    }
}
