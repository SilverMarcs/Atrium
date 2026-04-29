import Foundation

/// Compact "12.3K" / "1.2M" formatter for context-window token counts.
/// Used by the macOS navigation subtitle and the iOS context usage row,
/// so both surfaces show the same number for the same value.
public enum TokenFormatter {
    public static func format(_ count: Int) -> String {
        count.formatted(
            .number
                .notation(.compactName)
                .precision(.fractionLength(0...1))
        )
    }
}
