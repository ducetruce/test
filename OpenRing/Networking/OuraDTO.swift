import Foundation

/// Wire types for Oura API v2 (`https://cloud.ouraring.com/v2/usercollection/...`).
///
/// Decoded with `.convertFromSnakeCase`, so property names are the camelCase form of the
/// documented JSON keys. Timestamps stay `String` here and are parsed in `map()` — Oura mixes
/// fractional-second and whole-second ISO-8601, which trips the built-in date strategies.
enum OuraDTO {

    struct Page<Element: Decodable>: Decodable {
        var data: [Element]
        var nextToken: String?
    }

    struct SampleSeries: Decodable {
        var interval: Double
        var items: [Double?]
        var timestamp: String

        func map() -> Series? {
            guard let start = ISO8601.parse(timestamp), interval > 0 else { return nil }
            return Series(start: start, interval: interval, values: items)
        }
    }

    struct Sleep: Decodable {
        var id: String
        var day: String
        var bedtimeStart: String
        var bedtimeEnd: String
        var type: String?
        var timeInBed: Double?
        var totalSleepDuration: Double?
        var deepSleepDuration: Double?
        var lightSleepDuration: Double?
        var remSleepDuration: Double?
        var awakeTime: Double?
        var latency: Double?
        var efficiency: Double?
        var restlessPeriods: Int?
        var averageHeartRate: Double?
        var lowestHeartRate: Double?
        var averageHrv: Double?
        var averageBreath: Double?
        var sleepPhase5Min: String?
        var heartRate: SampleSeries?
        var hrv: SampleSeries?

        func map() -> SleepPeriod? {
            guard let day = Day(day),
                  let start = ISO8601.parse(bedtimeStart),
                  let end = ISO8601.parse(bedtimeEnd) else { return nil }
            return SleepPeriod(
                id: id,
                day: day,
                bedtimeStart: start,
                bedtimeEnd: end,
                type: type ?? "long_sleep",
                timeInBed: timeInBed ?? end.timeIntervalSince(start),
                totalSleep: totalSleepDuration ?? 0,
                deep: deepSleepDuration ?? 0,
                light: lightSleepDuration ?? 0,
                rem: remSleepDuration ?? 0,
                awake: awakeTime ?? 0,
                latency: latency,
                efficiency: efficiency,
                restlessPeriods: restlessPeriods,
                averageHeartRate: averageHeartRate,
                lowestHeartRate: lowestHeartRate,
                averageHRV: averageHrv,
                averageBreath: averageBreath,
                stages: SleepStage.parse(sleepPhase5Min ?? ""),
                heartRate: heartRate?.map(),
                hrv: hrv?.map(),
                cloudScore: nil
            )
        }
    }

    struct DailySleep: Decodable {
        var id: String
        var day: String
        var score: Int?
    }

    struct DailyActivity: Decodable {
        var id: String
        var day: String
        var score: Int?
        var steps: Int?
        var activeCalories: Double?
        var totalCalories: Double?
        var targetCalories: Double?
        var equivalentWalkingDistance: Double?
        var highActivityTime: Double?
        var mediumActivityTime: Double?
        var lowActivityTime: Double?
        var sedentaryTime: Double?
        var restingTime: Double?
        var nonWearTime: Double?
        var inactivityAlerts: Int?
        var highActivityMetMinutes: Double?
        var mediumActivityMetMinutes: Double?
        var lowActivityMetMinutes: Double?
        var averageMetMinutes: Double?
        var class5Min: String?
        var met: SampleSeries?

        func map() -> ActivityDay? {
            guard let day = Day(day) else { return nil }
            return ActivityDay(
                id: id,
                day: day,
                steps: steps ?? 0,
                activeCalories: activeCalories ?? 0,
                totalCalories: totalCalories ?? 0,
                targetCalories: targetCalories ?? 0,
                equivalentWalkingDistance: equivalentWalkingDistance ?? 0,
                highActivityMinutes: (highActivityTime ?? 0) / 60,
                mediumActivityMinutes: (mediumActivityTime ?? 0) / 60,
                lowActivityMinutes: (lowActivityTime ?? 0) / 60,
                sedentaryTime: sedentaryTime ?? 0,
                restingTime: restingTime ?? 0,
                nonWearTime: nonWearTime ?? 0,
                inactivityAlerts: inactivityAlerts ?? 0,
                highActivityMET: highActivityMetMinutes ?? 0,
                mediumActivityMET: mediumActivityMetMinutes ?? 0,
                lowActivityMET: lowActivityMetMinutes ?? 0,
                averageMET: averageMetMinutes ?? 0,
                classes: ActivityClass.parse(class5Min ?? ""),
                met: met?.map(),
                cloudScore: score
            )
        }
    }

    struct DailyReadiness: Decodable {
        var id: String
        var day: String
        var score: Int?
        var temperatureDeviation: Double?
        var temperatureTrendDeviation: Double?

        func map() -> ReadinessDay? {
            guard let day = Day(day) else { return nil }
            return ReadinessDay(
                id: id,
                day: day,
                cloudScore: score,
                temperatureDeviation: temperatureDeviation,
                temperatureTrendDeviation: temperatureTrendDeviation
            )
        }
    }

    struct DailySpO2: Decodable {
        struct Percentage: Decodable { var average: Double? }
        var id: String
        var day: String
        var spo2Percentage: Percentage?
        var breathingDisturbanceIndex: Double?

        func map() -> SpO2Day? {
            guard let day = Day(day) else { return nil }
            return SpO2Day(
                id: id,
                day: day,
                averagePercentage: spo2Percentage?.average,
                breathingDisturbanceIndex: breathingDisturbanceIndex
            )
        }
    }

    struct DailyStress: Decodable {
        var id: String
        var day: String
        var stressHigh: Double?
        var recoveryHigh: Double?
        var daySummary: String?

        func map() -> StressDay? {
            guard let day = Day(day) else { return nil }
            return StressDay(
                id: id,
                day: day,
                stressHigh: stressHigh,
                recoveryHigh: recoveryHigh,
                summary: daySummary
            )
        }
    }

    struct WorkoutDTO: Decodable {
        var id: String
        var day: String
        var activity: String
        var label: String?
        var intensity: String?
        var source: String?
        var calories: Double?
        var distance: Double?
        var startDatetime: String
        var endDatetime: String

        func map() -> Workout? {
            guard let day = Day(day),
                  let start = ISO8601.parse(startDatetime),
                  let end = ISO8601.parse(endDatetime) else { return nil }
            return Workout(
                id: id,
                day: day,
                activity: activity,
                label: label,
                intensity: intensity,
                source: source,
                calories: calories,
                distance: distance,
                start: start,
                end: end
            )
        }
    }

    struct PersonalInfoDTO: Decodable {
        var id: String?
        var age: Int?
        var weight: Double?
        var height: Double?
        var biologicalSex: String?
        var email: String?

        func map() -> PersonalInfo {
            PersonalInfo(id: id, age: age, weight: weight, height: height, biologicalSex: biologicalSex, email: email)
        }
    }
}

/// Oura returns both `2026-09-10T22:31:04.123-07:00` and `2026-09-10T22:31:04-07:00`.
enum ISO8601 {
    private static let withFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let withoutFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let lock = NSLock()

    static func parse(_ text: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return withFraction.date(from: text) ?? withoutFraction.date(from: text)
    }

    static func string(from date: Date) -> String {
        lock.lock()
        defer { lock.unlock() }
        return withoutFraction.string(from: date)
    }
}
