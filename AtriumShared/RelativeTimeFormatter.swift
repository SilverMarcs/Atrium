import Foundation

/// Compact "5m ago" / "2d 3h ago" formatter shared by the macOS chat
/// browser and the iOS companion's chat list. Bucket-based (month / week
/// / day / hour / minute) and capped at two parts so rows stay narrow.
public enum RelativeTimeFormatter {
    public static func shortRelative(from date: Date, now: Date = Date()) -> String {
        let interval = max(0, now.timeIntervalSince(date))
        if interval < 60 { return "now" }

        let components = Calendar.current.dateComponents(
            [.month, .weekOfYear, .day, .hour, .minute],
            from: date,
            to: now
        )

        var parts: [String] = []
        let pairs: [(Int?, String)] = [
            (components.month, "mo"),
            (components.weekOfYear, "w"),
            (components.day, "d"),
            (components.hour, "h"),
            (components.minute, "m")
        ]
        for (value, suffix) in pairs {
            guard parts.count < 2, let v = value, v > 0 else { continue }
            parts.append("\(v)\(suffix)")
        }

        if parts.isEmpty { return "now" }
        return parts.joined(separator: " ") + " ago"
    }
}
