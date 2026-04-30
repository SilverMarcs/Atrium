import Foundation

/// Compact "5m ago" / "3h ago" / "2d ago" formatter shared by the macOS
/// chat browser and the iOS companion's chat list. Shows a single bucket
/// from minutes upward (minute / hour / day) so rows stay narrow.
public enum RelativeTimeFormatter {
    public static func shortRelative(from date: Date, now: Date = Date()) -> String {
        let interval = max(0, now.timeIntervalSince(date))
        if interval < 60 { return "now" }

        let components = Calendar.current.dateComponents(
            [.day, .hour, .minute],
            from: date,
            to: now
        )

        if let d = components.day, d > 0 { return "\(d)d ago" }
        if let h = components.hour, h > 0 { return "\(h)h ago" }
        if let m = components.minute, m > 0 { return "\(m)m ago" }
        return "now"
    }
}
