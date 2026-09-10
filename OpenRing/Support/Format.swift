import Foundation

enum Format {
    /// "7h 42m" / "48m" — used everywhere a duration is shown.
    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours == 0 { return "\(minutes)m" }
        return "\(hours)h \(minutes)m"
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    private static let weekdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEE d MMM")
        return formatter
    }()

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    static func clockTime(_ date: Date) -> String { timeFormatter.string(from: date) }

    static func dayLabel(_ day: Day) -> String {
        if day == Day.today { return "Today" }
        if day == Day.today.adding(days: -1) { return "Yesterday" }
        return weekdayFormatter.string(from: day.startOfDay())
    }

    static func relative(_ date: Date) -> String {
        relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    static func number(_ value: Double, decimals: Int = 0) -> String {
        String(format: "%.\(decimals)f", value)
    }

    static func integer(_ value: Int) -> String {
        value.formatted(.number.grouping(.automatic))
    }
}
