import Foundation

/// Wire types for Oura API v2 (`https://cloud.ouraring.com/v2/usercollection/...`).
///
/// Decoded with `.convertFromSnakeCase`, so property names are the camelCase form of the
/// documented JSON keys. Timestamps stay `String` here and are parsed in `map()` — Oura mixes
/// fractional-second and whole-second ISO-8601, which trips the built-in date strategies.
enum OuraDTO {

    /// Decodes each record independently.
    ///
    /// A plain `[Element]` is all or nothing: one record with an unexpected shape throws,
    /// and the endpoint yields nothing at all. Six months of blood oxygen can vanish
    /// because a single row lacks a field. Skipping the bad row and counting it is both
    /// more useful and more honest than losing the lot.
    struct Page<Element: Decodable>: Decodable {
        var data: [Element] = []
        var nextToken: String?
        /// Records that failed to decode, surfaced so a silent shape change is visible.
        var skipped: Int = 0

        private enum CodingKeys: String, CodingKey { case data, nextToken }

        private struct Lenient: Decodable {
            let value: Element?
            init(from decoder: Decoder) throws {
                value = try? Element(from: decoder)
            }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            nextToken = try container.decodeIfPresent(String.self, forKey: .nextToken)
            let rows = try container.decodeIfPresent([Lenient].self, forKey: .data) ?? []
            data = rows.compactMap(\.value)
            skipped = rows.count - data.count
        }
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
        var id: String?
        var day: String
        var spo2Percentage: Percentage?
        var breathingDisturbanceIndex: Double?

        func map() -> SpO2Day? {
            guard let day = Day(day) else { return nil }
            return SpO2Day(
                id: id ?? "spo2-\(day)",
                day: day,
                averagePercentage: spo2Percentage?.average,
                breathingDisturbanceIndex: breathingDisturbanceIndex
            )
        }
    }

    struct DailyStress: Decodable {
        var id: String?
        var day: String
        var stressHigh: Double?
        var recoveryHigh: Double?
        var daySummary: String?

        func map() -> StressDay? {
            guard let day = Day(day) else { return nil }
            return StressDay(
                id: id ?? "stress-\(day)",
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

    struct DailyCardiovascularAge: Decodable {
        var id: String?
        var day: String
        var vascularAge: Double?

        func map() -> CardiovascularAgeDay? {
            guard let day = Day(day) else { return nil }
            return CardiovascularAgeDay(id: id ?? "cva-\(day)", day: day, vascularAge: vascularAge)
        }
    }

    struct DailyResilience: Decodable {
        struct Contributors: Decodable {
            var sleepRecovery: Double?
            var daytimeRecovery: Double?
            var stress: Double?
        }
        var id: String?
        var day: String
        var level: String?
        var contributors: Contributors?

        func map() -> ResilienceDay? {
            guard let day = Day(day) else { return nil }
            return ResilienceDay(
                id: id ?? "res-\(day)", day: day, level: level,
                sleepRecovery: contributors?.sleepRecovery,
                daytimeRecovery: contributors?.daytimeRecovery,
                stress: contributors?.stress
            )
        }
    }

    struct VO2Max: Decodable {
        var id: String?
        var day: String
        var vo2Max: Double?

        func map() -> VO2MaxDay? {
            guard let day = Day(day) else { return nil }
            return VO2MaxDay(id: id ?? "vo2-\(day)", day: day, vo2Max: vo2Max)
        }
    }

    struct SleepTime: Decodable {
        struct Bedtime: Decodable {
            var startOffset: Int?
            var endOffset: Int?
        }
        var id: String?
        var day: String
        var status: String?
        var recommendation: String?
        var optimalBedtime: Bedtime?

        func map() -> SleepTimeDay? {
            guard let day = Day(day) else { return nil }
            return SleepTimeDay(
                id: id ?? "st-\(day)", day: day, status: status, recommendation: recommendation,
                optimalBedtimeStartOffset: optimalBedtime?.startOffset,
                optimalBedtimeEndOffset: optimalBedtime?.endOffset
            )
        }
    }

    struct SessionDTO: Decodable {
        var id: String?
        var day: String
        var type: String?
        var mood: String?
        var startDatetime: String
        var endDatetime: String

        func map() -> MomentSession? {
            guard let day = Day(day),
                  let start = ISO8601.parse(startDatetime),
                  let end = ISO8601.parse(endDatetime) else { return nil }
            return MomentSession(id: id ?? "sess-\(startDatetime)", day: day,
                                 type: type ?? "session", mood: mood, start: start, end: end)
        }
    }

    struct TagDTO: Decodable {
        var id: String?
        var day: String
        var tagTypeCode: String?
        var comment: String?
        var startTime: String?
        /// `enhanced_tag` returns several codes; the older `tag` endpoint returns one.
        var tags: [String]?

        func map() -> DayTag? {
            guard let day = Day(day) else { return nil }
            let codes = tags ?? tagTypeCode.map { [$0] } ?? []
            guard !codes.isEmpty || comment != nil else { return nil }
            return DayTag(id: id ?? "tag-\(day)-\(codes.joined())", day: day, codes: codes,
                          comment: comment, start: startTime.flatMap(ISO8601.parse))
        }
    }

    struct RestModePeriodDTO: Decodable {
        var id: String?
        var startDay: String?
        var endDay: String?
        var episodes: [Episode]?
        struct Episode: Decodable { var tags: [String]? }

        func map() -> RestModePeriod? {
            let start = startDay.flatMap(Day.init)
            let end = endDay.flatMap(Day.init)
            guard start != nil || end != nil else { return nil }
            return RestModePeriod(id: id ?? "rest-\(startDay ?? "")", start: start, end: end,
                                  episodeCount: episodes?.count ?? 0)
        }
    }

    struct RingConfiguration: Decodable {
        var id: String?
        var colour: String?
        var color: String?
        var design: String?
        var hardwareType: String?
        var size: Int?
        var setUpAt: String?

        func map(battery: Int?) -> RingInfo {
            RingInfo(id: id, design: design, colour: colour ?? color, hardwareType: hardwareType,
                     size: size, batteryPercentage: battery,
                     updatedAt: setUpAt.flatMap(ISO8601.parse))
        }
    }

    struct RingBattery: Decodable {
        var batteryLevel: Int?
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
