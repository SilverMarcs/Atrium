import AtriumProtocol

extension SnoozeDuration {
    /// The durations a task's Snooze menu always shows.
    static let menu: [SnoozeDuration] = [.oneHour, .threeHours, .sixHours, .oneDay]
    /// The longer ones, under More.
    static let more: [SnoozeDuration] = [.twoDays, .threeDays, .fiveDays]

    var title: String {
        switch self {
        case .oneHour: "1 Hour"
        case .threeHours: "3 Hours"
        case .sixHours: "6 Hours"
        case .oneDay: "1 Day"
        case .twoDays: "2 Days"
        case .threeDays: "3 Days"
        case .fiveDays: "5 Days"
        }
    }
}
