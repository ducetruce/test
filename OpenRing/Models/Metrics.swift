import Foundation

/// One plotted sample. A named type rather than a tuple because Swift key paths — which
/// Swift Charts needs for identity — cannot address tuple elements.
struct SeriesPoint: Identifiable, Hashable {
    var date: Date
    var value: Double

    var id: Date { date }
}

/// A regularly-sampled series (heart rate, HRV, MET), as Oura returns them.
struct Series: Codable, Hashable {
    var start: Date
    /// Seconds between samples.
    var interval: TimeInterval
    /// `nil` entries are gaps (ring off the finger, dropped samples).
    var values: [Double?]

    var isEmpty: Bool { values.compactMap { $0 }.isEmpty }

    func timestamp(at index: Int) -> Date {
        start.addingTimeInterval(interval * Double(index))
    }

    var points: [SeriesPoint] {
        values.enumerated().compactMap { index, value in
            guard let value else { return nil }
            return SeriesPoint(date: timestamp(at: index), value: value)
        }
    }

    var average: Double? {
        let present = values.compactMap { $0 }
        guard !present.isEmpty else { return nil }
        return present.reduce(0, +) / Double(present.count)
    }

    var minimum: Double? { values.compactMap { $0 }.min() }

    /// Fraction of the series (0...1) at which the lowest value occurs.
    var minimumPosition: Double? {
        var bestIndex: Int?
        var bestValue = Double.greatestFiniteMagnitude
        for (index, value) in values.enumerated() {
            guard let value else { continue }
            if value < bestValue {
                bestValue = value
                bestIndex = index
            }
        }
        guard let bestIndex, values.count > 1 else { return nil }
        return Double(bestIndex) / Double(values.count - 1)
    }
}

enum SleepStage: Int, Codable, Hashable, CaseIterable {
    case deep = 1
    case light = 2
    case rem = 3
    case awake = 4

    var label: String {
        switch self {
        case .deep: return "Deep"
        case .light: return "Light"
        case .rem: return "REM"
        case .awake: return "Awake"
        }
    }

    /// Oura encodes one character per 5 minutes in `sleep_phase_5_min`.
    static func parse(_ encoded: String) -> [SleepStage] {
        encoded.compactMap { character in
            guard let digit = character.wholeNumberValue else { return nil }
            return SleepStage(rawValue: digit)
        }
    }
}

enum ActivityClass: Int, Codable, Hashable, CaseIterable {
    case nonWear = 0
    case rest = 1
    case inactive = 2
    case low = 3
    case medium = 4
    case high = 5

    var label: String {
        switch self {
        case .nonWear: return "Not worn"
        case .rest: return "Rest"
        case .inactive: return "Inactive"
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        }
    }

    /// Oura encodes one character per 5 minutes in `class_5_min`.
    static func parse(_ encoded: String) -> [ActivityClass] {
        encoded.compactMap { character in
            guard let digit = character.wholeNumberValue else { return nil }
            return ActivityClass(rawValue: digit)
        }
    }
}

/// One sleep period (a night, or a nap). Oura can report several per day.
struct SleepPeriod: Codable, Hashable, Identifiable {
    var id: String
    var day: Day
    var bedtimeStart: Date
    var bedtimeEnd: Date
    var type: String
    var timeInBed: TimeInterval
    var totalSleep: TimeInterval
    var deep: TimeInterval
    var light: TimeInterval
    var rem: TimeInterval
    var awake: TimeInterval
    var latency: TimeInterval?
    var efficiency: Double?
    var restlessPeriods: Int?
    var averageHeartRate: Double?
    var lowestHeartRate: Double?
    var averageHRV: Double?
    var averageBreath: Double?
    var stages: [SleepStage]
    var heartRate: Series?
    var hrv: Series?
    /// Score computed by Oura's cloud, when the account still returns one.
    var cloudScore: Int?

    /// Long sleeps are the "main" night; naps are excluded from nightly scoring.
    var isMainSleep: Bool { type == "long_sleep" || type == "sleep" }

    var midpoint: Date {
        bedtimeStart.addingTimeInterval(bedtimeEnd.timeIntervalSince(bedtimeStart) / 2)
    }

    var restlessPeriodsPerHour: Double? {
        guard let restlessPeriods, totalSleep > 0 else { return nil }
        return Double(restlessPeriods) / (totalSleep / 3600)
    }
}

struct ActivityDay: Codable, Hashable, Identifiable {
    var id: String
    var day: Day
    var steps: Int
    var activeCalories: Double
    var totalCalories: Double
    var targetCalories: Double
    var equivalentWalkingDistance: Double
    var highActivityMinutes: Double
    var mediumActivityMinutes: Double
    var lowActivityMinutes: Double
    var sedentaryTime: TimeInterval
    var restingTime: TimeInterval
    var nonWearTime: TimeInterval
    var inactivityAlerts: Int
    var highActivityMET: Double
    var mediumActivityMET: Double
    var lowActivityMET: Double
    var averageMET: Double
    var classes: [ActivityClass]
    var met: Series?
    var cloudScore: Int?

    /// MET-minutes that count as training load.
    var trainingMETMinutes: Double { highActivityMET + mediumActivityMET }
}

/// Oura's own readiness output. Kept so trends survive even if the cloud stops scoring.
struct ReadinessDay: Codable, Hashable, Identifiable {
    var id: String
    var day: Day
    var cloudScore: Int?
    var temperatureDeviation: Double?
    var temperatureTrendDeviation: Double?
}

struct SpO2Day: Codable, Hashable, Identifiable {
    var id: String
    var day: Day
    var averagePercentage: Double?
    var breathingDisturbanceIndex: Double?
}

struct StressDay: Codable, Hashable, Identifiable {
    var id: String
    var day: Day
    var stressHigh: TimeInterval?
    var recoveryHigh: TimeInterval?
    var summary: String?
}

struct Workout: Codable, Hashable, Identifiable {
    var id: String
    var day: Day
    var activity: String
    var label: String?
    var intensity: String?
    var source: String?
    var calories: Double?
    var distance: Double?
    var start: Date
    var end: Date

    var duration: TimeInterval { end.timeIntervalSince(start) }
}

struct PersonalInfo: Codable, Hashable {
    var id: String?
    var age: Int?
    var weight: Double?
    var height: Double?
    var biologicalSex: String?
    var email: String?
}
