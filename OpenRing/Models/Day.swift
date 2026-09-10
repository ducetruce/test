import Foundation

/// A calendar date without a time component, matching Oura's `day` field ("YYYY-MM-DD").
///
/// Oura reports a `day` in the *ring wearer's* local calendar, so all arithmetic here uses
/// `Calendar.current`. Storing year/month/day rather than a `Date` keeps round-tripping
/// through JSON stable across timezone changes.
struct Day: Hashable, Comparable, Codable, Identifiable, CustomStringConvertible {
    let year: Int
    let month: Int
    let day: Int

    init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    init?(_ text: String) {
        let parts = text.prefix(10).split(separator: "-")
        guard parts.count == 3,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]) else { return nil }
        self.init(year: y, month: m, day: d)
    }

    init(date: Date, calendar: Calendar = .current) {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: c.year ?? 1970, month: c.month ?? 1, day: c.day ?? 1)
    }

    static var today: Day { Day(date: Date()) }

    var id: String { description }

    var description: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    func startOfDay(in calendar: Calendar = .current) -> Date {
        var c = DateComponents()
        c.year = year
        c.month = month
        c.day = day
        return calendar.date(from: c) ?? Date(timeIntervalSince1970: 0)
    }

    func adding(days offset: Int, calendar: Calendar = .current) -> Day {
        let base = startOfDay(in: calendar)
        let moved = calendar.date(byAdding: .day, value: offset, to: base) ?? base
        return Day(date: moved, calendar: calendar)
    }

    /// Number of days from `other` to `self` (negative if `self` is earlier).
    func distance(from other: Day, calendar: Calendar = .current) -> Int {
        let comps = calendar.dateComponents([.day], from: other.startOfDay(in: calendar), to: startOfDay(in: calendar))
        return comps.day ?? 0
    }

    static func range(from start: Day, through end: Day) -> [Day] {
        guard start <= end else { return [] }
        var result: [Day] = []
        var cursor = start
        while cursor <= end {
            result.append(cursor)
            cursor = cursor.adding(days: 1)
        }
        return result
    }

    static func < (lhs: Day, rhs: Day) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    // Encoded as the plain "YYYY-MM-DD" string so the on-disk database stays readable.
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let parsed = Day(text) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid day: \(text)")
        }
        self = parsed
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}
