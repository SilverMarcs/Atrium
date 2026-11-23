import Foundation

/// How long a task stays snoozed before it comes back.
public nonisolated enum SnoozeDuration: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    case oneHour = "1h"
    case threeHours = "3h"
    case sixHours = "6h"
    case oneDay = "1d"
    case twoDays = "2d"
    case threeDays = "3d"
    case fiveDays = "5d"

    /// What swiping snoozes for until the host's setting is changed.
    public static let `default`: SnoozeDuration = .oneDay

    public var id: Self { self }

    /// When a snooze starting at `start` ends, in local time: a day keeps the
    /// time of day across daylight saving changes.
    public func end(from start: Date = .now, in calendar: Calendar = .current) -> Date {
        let (component, value): (Calendar.Component, Int) = switch self {
        case .oneHour: (.hour, 1)
        case .threeHours: (.hour, 3)
        case .sixHours: (.hour, 6)
        case .oneDay: (.day, 1)
        case .twoDays: (.day, 2)
        case .threeDays: (.day, 3)
        case .fiveDays: (.day, 5)
        }
        return calendar.date(byAdding: component, value: value, to: start) ?? start
    }
}
