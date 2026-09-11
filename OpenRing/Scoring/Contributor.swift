import Foundation

/// One weighted input to a score, kept alongside the score so the UI can show *why*
/// a number came out the way it did.
struct Contributor: Codable, Hashable, Identifiable {
    var id: String
    var label: String
    var score: Double
    var weight: Double
    var detail: String

    var rounded: Int { Int(Curve.clamp(score).rounded()) }
}

enum ScoreKind: String, Codable, Hashable, CaseIterable {
    case sleep, readiness, activity

    var title: String {
        switch self {
        case .sleep: return "Sleep"
        case .readiness: return "Readiness"
        case .activity: return "Activity"
        }
    }
}

struct Score: Codable, Hashable {
    var kind: ScoreKind
    var value: Int
    var contributors: [Contributor]
    /// Oura's own number for the same day, when the account still returns one.
    var cloudValue: Int?

    /// Share of the total contributor weight that was actually available, 0...1.
    ///
    /// Missing signals are re-weighted rather than zeroed, which is correct, but it means a
    /// score can be assembled from a minority of its inputs and still read as confident.
    /// A night with no sleep record loses HRV, resting heart rate, previous night and
    /// recovery index — 56% of readiness — and what remains is not the same measurement.
    var coverage: Double = 1

    /// Below this, the score is shown qualified rather than plain.
    var isPartial: Bool { coverage < 0.7 }

    var availableContributorCount: Int { contributors.count }

    var label: String {
        switch value {
        case 85...: return "Optimal"
        case 70..<85: return "Good"
        case 60..<70: return "Fair"
        default: return "Pay attention"
        }
    }
}

/// All locally computed scores for a single day.
struct DayScores: Codable, Hashable, Identifiable {
    var day: Day
    var sleep: Score? = nil
    var readiness: Score? = nil
    var activity: Score? = nil

    var id: String { day.description }
}
