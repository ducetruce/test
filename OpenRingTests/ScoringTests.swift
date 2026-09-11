import XCTest
@testable import OpenRing

final class CurveTests: XCTestCase {
    func testClampsOutsideControlPoints() {
        let points: [(x: Double, y: Double)] = [(0, 10), (10, 90)]
        XCTAssertEqual(Curve.score(-5, points), 10)
        XCTAssertEqual(Curve.score(50, points), 90)
    }

    func testInterpolatesBetweenControlPoints() {
        let points: [(x: Double, y: Double)] = [(0, 0), (10, 100)]
        XCTAssertEqual(Curve.score(5, points), 50, accuracy: 0.0001)
        XCTAssertEqual(Curve.score(2.5, points), 25, accuracy: 0.0001)
    }
}

final class DayTests: XCTestCase {
    func testParsingAndDescription() {
        let day = Day("2026-03-09")
        XCTAssertEqual(day?.description, "2026-03-09")
        XCTAssertNil(Day("not-a-day"))
    }

    func testArithmeticCrossesMonthBoundaries() {
        let day = Day(year: 2026, month: 3, day: 1)
        XCTAssertEqual(day.adding(days: -1).description, "2026-02-28")
        XCTAssertEqual(day.adding(days: 31).description, "2026-04-01")
    }

    func testRangeIsInclusive() {
        let start = Day(year: 2026, month: 1, day: 1)
        let end = Day(year: 2026, month: 1, day: 5)
        XCTAssertEqual(Day.range(from: start, through: end).count, 5)
        XCTAssertTrue(Day.range(from: end, through: start).isEmpty)
    }

    func testCodableRoundTrip() throws {
        let day = Day(year: 2026, month: 12, day: 31)
        let data = try JSONEncoder().encode(day)
        XCTAssertEqual(String(data: data, encoding: .utf8), "\"2026-12-31\"")
        XCTAssertEqual(try JSONDecoder().decode(Day.self, from: data), day)
    }
}

final class ScoreEngineTests: XCTestCase {
    private let engine = ScoreEngine()

    func testGoodNightScoresWellAndBadNightDoesNot() throws {
        let day = Day(year: 2026, month: 5, day: 10)
        var database = Database()
        database.sleep = [Fixtures.night(day: day, hours: 8, deepShare: 0.17, remShare: 0.22, efficiency: 94, restless: 12)]
        let good = try XCTUnwrap(engine.sleepScore(for: day, in: database))
        XCTAssertGreaterThan(good.value, 80)

        database.sleep = [Fixtures.night(day: day, hours: 4.5, deepShare: 0.05, remShare: 0.07, efficiency: 68, restless: 60, latencyMinutes: 55)]
        let bad = try XCTUnwrap(engine.sleepScore(for: day, in: database))
        XCTAssertLessThan(bad.value, 60)
    }

    func testElevatedRestingHeartRateLowersReadiness() throws {
        let day = Day(year: 2026, month: 5, day: 20)
        var database = Database()
        // Two weeks of steady baseline nights, then the night being scored.
        database.sleep = Day.range(from: day.adding(days: -14), through: day.adding(days: -1)).map {
            Fixtures.night(day: $0, hours: 7.5, restingHR: 52, hrv: 60)
        }

        database.sleep.append(Fixtures.night(day: day, hours: 7.5, restingHR: 52, hrv: 60))
        let steady = engine.readinessScore(for: day, in: database, sleepScore: engine.sleepScore(for: day, in: database))

        database.sleep.removeLast()
        database.sleep.append(Fixtures.night(day: day, hours: 7.5, restingHR: 62, hrv: 34))
        let strained = engine.readinessScore(for: day, in: database, sleepScore: engine.sleepScore(for: day, in: database))

        let steadyScore = try XCTUnwrap(steady)
        let strainedScore = try XCTUnwrap(strained)
        XCTAssertGreaterThan(steadyScore.value, strainedScore.value + 10)
    }

    func testMissingContributorsAreRenormalisedNotZeroed() throws {
        let day = Day(year: 2026, month: 6, day: 1)
        var database = Database()
        // A night with no HRV, no temperature and no history to build baselines from.
        var sparse = Fixtures.night(day: day, hours: 7.5)
        sparse.averageHRV = nil
        sparse.lowestHeartRate = nil
        database.sleep = [sparse]

        let readiness = try XCTUnwrap(
            engine.readinessScore(for: day, in: database, sleepScore: engine.sleepScore(for: day, in: database))
        )
        // Only "previous night" survives, so readiness should track the sleep score rather
        // than collapse toward zero.
        XCTAssertGreaterThan(readiness.value, 60)
    }

    /// A readiness score assembled without a sleep record is missing HRV, resting heart
    /// rate, previous night and recovery index — most of the weight — and must say so.
    func testReadinessWithoutASleepRecordIsMarkedPartial() throws {
        let day = Day(year: 2026, month: 9, day: 10)
        var database = Database()
        database.merge(readiness: [ReadinessDay(
            id: "r", day: day, cloudScore: 71,
            temperatureDeviation: -0.13, temperatureTrendDeviation: nil
        )])

        let readiness = try XCTUnwrap(engine.readinessScore(for: day, in: database, sleepScore: nil))
        XCTAssertTrue(readiness.isPartial, "coverage was \(readiness.coverage)")
        XCTAssertLessThan(readiness.coverage, 0.5)
        XCTAssertEqual(readiness.cloudValue, 71)
    }

    func testAFullNightIsNotMarkedPartial() throws {
        let day = Day(year: 2026, month: 9, day: 10)
        var database = Database()
        database.sleep = Day.range(from: day.adding(days: -14), through: day).map {
            Fixtures.night(day: $0, hours: 7.5)
        }
        database.activity = Day.range(from: day.adding(days: -28), through: day).map {
            Fixtures.activity(day: $0, steps: 9000, activeCalories: 450)
        }
        database.merge(readiness: [ReadinessDay(
            id: "r", day: day, cloudScore: 80,
            temperatureDeviation: 0.05, temperatureTrendDeviation: nil
        )])

        let sleep = engine.sleepScore(for: day, in: database)
        let readiness = try XCTUnwrap(engine.readinessScore(for: day, in: database, sleepScore: sleep))
        XCTAssertFalse(readiness.isPartial, "coverage was \(readiness.coverage)")
        XCTAssertGreaterThan(readiness.coverage, 0.9)
    }

    func testCoverageNeverExceedsOne() throws {
        let day = Day(year: 2026, month: 9, day: 10)
        var database = Database()
        database.sleep = [Fixtures.night(day: day, hours: 8)]
        let sleep = try XCTUnwrap(engine.sleepScore(for: day, in: database))
        XCTAssertEqual(sleep.coverage, 1, accuracy: 0.0001)
        XCTAssertFalse(sleep.isPartial)
    }

    func testScoresStayInRange() {
        let day = Day(year: 2026, month: 7, day: 4)
        var database = Database()
        database.sleep = [Fixtures.night(day: day, hours: 14, deepShare: 0.5, remShare: 0.4, efficiency: 100, restless: 0)]
        database.activity = [Fixtures.activity(day: day, steps: 90_000, activeCalories: 4000)]

        let scores = engine.scores(for: day, in: database)
        for value in [scores.sleep?.value, scores.activity?.value].compactMap({ $0 }) {
            XCTAssertTrue((1...100).contains(value), "score \(value) out of range")
        }
    }

    func testActivityScoreRewardsHittingTheTarget() throws {
        let day = Day(year: 2026, month: 8, day: 8)
        var database = Database()
        database.activity = [Fixtures.activity(day: day, steps: 12_000, activeCalories: 520, targetCalories: 500, sedentaryHours: 5)]
        let hit = engine.activityScore(for: day, in: database)

        database.activity = [Fixtures.activity(day: day, steps: 900, activeCalories: 80, targetCalories: 500, sedentaryHours: 13)]
        let missed = engine.activityScore(for: day, in: database)

        let hitScore = try XCTUnwrap(hit)
        let missedScore = try XCTUnwrap(missed)
        // The calibrated daily-target curve is far flatter than the original guess, so
        // hitting the target separates less sharply than it used to.
        XCTAssertGreaterThan(hitScore.value, missedScore.value + 15)
    }
}

final class DatabaseTests: XCTestCase {
    func testMergeUpsertsByIdentifier() {
        let day = Day(year: 2026, month: 2, day: 2)
        var database = Database()
        database.merge(sleep: [Fixtures.night(day: day, hours: 6)])
        database.merge(sleep: [Fixtures.night(day: day, hours: 8)])

        XCTAssertEqual(database.sleep.count, 1, "same id should replace, not duplicate")
        XCTAssertEqual(database.mainSleep(on: day)?.totalSleep, 8 * 3600)
    }

    func testMainSleepPrefersTheLongSleepOverNaps() {
        let day = Day(year: 2026, month: 2, day: 3)
        var nap = Fixtures.night(day: day, hours: 1)
        nap.id = "nap"
        nap.type = "late_nap"
        var database = Database()
        database.merge(sleep: [nap, Fixtures.night(day: day, hours: 7)])

        XCTAssertEqual(database.mainSleep(on: day)?.totalSleep, 7 * 3600)
        XCTAssertEqual(database.naps(on: day).count, 1)
    }
}

/// Pins the snake_case -> camelCase mapping. If Oura renames a field this test fails
/// instead of the app silently showing zeros.
final class DecodingTests: XCTestCase {
    func testDecodesASleepPayload() throws {
        let json = """
        {
          "data": [
            {
              "id": "abc",
              "day": "2026-04-01",
              "bedtime_start": "2026-03-31T23:10:05.000-07:00",
              "bedtime_end": "2026-04-01T07:02:05-07:00",
              "type": "long_sleep",
              "time_in_bed": 28320,
              "total_sleep_duration": 26400,
              "deep_sleep_duration": 4800,
              "light_sleep_duration": 15600,
              "rem_sleep_duration": 6000,
              "awake_time": 1920,
              "latency": 780,
              "efficiency": 93,
              "restless_periods": 24,
              "average_heart_rate": 56.5,
              "lowest_heart_rate": 48,
              "average_hrv": 62,
              "average_breath": 14.3,
              "sleep_phase_5_min": "4321122",
              "heart_rate": { "interval": 300.0, "items": [60, null, 55], "timestamp": "2026-03-31T23:10:05-07:00" }
            }
          ],
          "next_token": null
        }
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let page = try decoder.decode(OuraDTO.Page<OuraDTO.Sleep>.self, from: Data(json.utf8))
        let night = try XCTUnwrap(page.data.first?.map())

        XCTAssertEqual(night.day.description, "2026-04-01")
        XCTAssertEqual(night.totalSleep, 26400)
        XCTAssertEqual(night.deep, 4800)
        XCTAssertEqual(night.rem, 6000)
        XCTAssertEqual(night.lowestHeartRate, 48)
        XCTAssertEqual(night.averageHRV, 62)
        XCTAssertEqual(night.stages, [.awake, .rem, .light, .deep, .deep, .light, .light])
        XCTAssertEqual(night.heartRate?.values.count, 3)
        XCTAssertEqual(night.heartRate?.interval, 300)
        XCTAssertTrue(night.isMainSleep)
    }

    func testDecodesAnActivityPayload() throws {
        let json = """
        {
          "data": [
            {
              "id": "act",
              "day": "2026-04-01",
              "score": 88,
              "steps": 10345,
              "active_calories": 512,
              "total_calories": 2480,
              "target_calories": 500,
              "equivalent_walking_distance": 8200,
              "high_activity_time": 900,
              "medium_activity_time": 2400,
              "low_activity_time": 9000,
              "sedentary_time": 21600,
              "resting_time": 30000,
              "non_wear_time": 0,
              "inactivity_alerts": 1,
              "high_activity_met_minutes": 120,
              "medium_activity_met_minutes": 180,
              "low_activity_met_minutes": 210,
              "average_met_minutes": 1.6,
              "class_5_min": "012345"
            }
          ]
        }
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let page = try decoder.decode(OuraDTO.Page<OuraDTO.DailyActivity>.self, from: Data(json.utf8))
        let activity = try XCTUnwrap(page.data.first?.map())

        XCTAssertEqual(activity.steps, 10345)
        XCTAssertEqual(activity.activeCalories, 512)
        XCTAssertEqual(activity.highActivityMinutes, 15)
        XCTAssertEqual(activity.trainingMETMinutes, 300)
        XCTAssertEqual(activity.cloudScore, 88)
        XCTAssertEqual(activity.classes, [.nonWear, .rest, .inactive, .low, .medium, .high])
    }
}

enum Fixtures {
    static func night(
        day: Day,
        hours: Double,
        deepShare: Double = 0.16,
        remShare: Double = 0.21,
        efficiency: Double = 92,
        restless: Int = 20,
        latencyMinutes: Double = 15,
        restingHR: Double = 52,
        hrv: Double = 60,
        midpointHour: Double = 3
    ) -> SleepPeriod {
        let total = hours * 3600
        // Bedtime chosen so the midpoint lands at `midpointHour` (03:00 by default, the
        // engine's ideal).
        let start = day.startOfDay().addingTimeInterval(midpointHour * 3600 - total / 2)
        return SleepPeriod(
            id: "sleep-\(day)",
            day: day,
            bedtimeStart: start,
            bedtimeEnd: start.addingTimeInterval(total / (efficiency / 100)),
            type: "long_sleep",
            timeInBed: total / (efficiency / 100),
            totalSleep: total,
            deep: total * deepShare,
            light: total * (1 - deepShare - remShare),
            rem: total * remShare,
            awake: total * 0.05,
            latency: latencyMinutes * 60,
            efficiency: efficiency,
            restlessPeriods: restless,
            averageHeartRate: restingHR + 6,
            lowestHeartRate: restingHR,
            averageHRV: hrv,
            averageBreath: 14.2,
            stages: [],
            heartRate: nil,
            hrv: nil,
            cloudScore: nil
        )
    }

    static func activity(
        day: Day,
        steps: Int,
        activeCalories: Double,
        targetCalories: Double = 500,
        sedentaryHours: Double = 7
    ) -> ActivityDay {
        ActivityDay(
            id: "activity-\(day)",
            day: day,
            steps: steps,
            activeCalories: activeCalories,
            totalCalories: activeCalories + 1800,
            targetCalories: targetCalories,
            equivalentWalkingDistance: Double(steps) * 0.75,
            highActivityMinutes: 15,
            mediumActivityMinutes: 40,
            lowActivityMinutes: 150,
            sedentaryTime: sedentaryHours * 3600,
            restingTime: 8 * 3600,
            nonWearTime: 0,
            inactivityAlerts: 1,
            highActivityMET: 120,
            mediumActivityMET: 180,
            lowActivityMET: 210,
            averageMET: 1.6,
            classes: [],
            met: nil,
            cloudScore: nil
        )
    }
}

final class CalibrationExportTests: XCTestCase {
    private func database(days: Int) -> Database {
        var database = Database()
        let end = Day(year: 2026, month: 6, day: 30)
        let range = Day.range(from: end.adding(days: -(days - 1)), through: end)
        database.sleep = range.map { Fixtures.night(day: $0, hours: 7.5) }
        database.activity = range.map { Fixtures.activity(day: $0, steps: 9000, activeCalories: 450) }
        return database
    }

    func testHeaderMatchesTheColumnCountOfEveryRow() {
        let db = database(days: 60)
        let csv = CalibrationExport.csv(database: db, scores: ScoreEngine().allScores(in: db))
        let lines = csv.split(separator: "\n").map(String.init)
        XCTAssertGreaterThan(lines.count, 1)
        let expected = CalibrationExport.columns.count
        for line in lines {
            XCTAssertEqual(line.components(separatedBy: ",").count, expected, "ragged row: \(line)")
        }
    }

    /// Baselines need time to fill, so those days would teach the wrong lesson.
    func testWarmUpDaysAreExcluded() {
        let db = database(days: 60)
        let csv = CalibrationExport.csv(database: db, scores: ScoreEngine().allScores(in: db), warmUpDays: 28)
        let rows = csv.split(separator: "\n").dropFirst()
        XCTAssertEqual(rows.count, 32, "60 days minus a 28 day warm-up")
        XCTAssertFalse(csv.contains("2026-05-02"), "first day should be skipped")
    }

    /// A zero would be fitted as a real measurement; a gap has to stay a gap.
    func testMissingValuesAreEmptyNotZero() {
        var db = database(days: 40)
        db.activity = []
        let csv = CalibrationExport.csv(database: db, scores: ScoreEngine().allScores(in: db))
        let row = try? XCTUnwrap(csv.split(separator: "\n").dropFirst().first.map(String.init))
        let fields = (row ?? "").components(separatedBy: ",")
        // Steps sits at a known offset and has no data here.
        let stepsIndex = CalibrationExport.columns.firstIndex(of: "steps") ?? 0
        XCTAssertEqual(fields[safe: stepsIndex], "")
    }

    func testEmptyDatabaseStillEmitsAHeader() {
        let csv = CalibrationExport.csv(database: Database(), scores: [:])
        XCTAssertEqual(csv.trimmingCharacters(in: .whitespacesAndNewlines), CalibrationExport.columns.joined(separator: ","))
    }

    /// `midpoint_dev_hr` used to be computed against a hard-coded 3am reference, independent
    /// of the personal rolling baseline the live `timing` contributor actually reads — so a
    /// row exported for fitting was describing an input the score never saw. This nights the
    /// person consistently at 06:00, where a habitual baseline has settled after five nights:
    /// the exported deviation on night six must reflect that baseline, not a fixed clock.
    func testMidpointDeviationMatchesTheEnginesPersonalBaselineNotAFixedClock() throws {
        var database = Database()
        let day = Day(year: 2026, month: 6, day: 20)
        let range = Day.range(from: day.adding(days: -6), through: day)
        database.sleep = range.map { Fixtures.night(day: $0, hours: 7.5, midpointHour: 6) }
        database.activity = range.map { Fixtures.activity(day: $0, steps: 9000, activeCalories: 450) }

        let csv = CalibrationExport.csv(
            database: database, scores: ScoreEngine().allScores(in: database), warmUpDays: 0
        )
        let lastRow = try? XCTUnwrap(csv.split(separator: "\n").last.map(String.init))
        let mpdIndex = CalibrationExport.columns.firstIndex(of: "midpoint_dev_hr") ?? 0
        let deviation = Double((lastRow ?? "").components(separatedBy: ",")[safe: mpdIndex] ?? "")

        let deviationHours = try XCTUnwrap(deviation)
        // Against the personal baseline (~06:00) the deviation should be near zero. The old
        // fixed-3am proxy would have reported roughly 3 here instead.
        XCTAssertLessThan(deviationHours, 0.5, "exported deviation should track the habitual baseline, not a fixed 3am reference")
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

final class HabitualMidpointTests: XCTestCase {
    private let engine = ScoreEngine()

    /// A plain mean of midnight-adjacent times lands at midday; the circular mean must not.
    func testCircularMeanHandlesMidnightWrap() throws {
        let day = Day(year: 2026, month: 5, day: 20)
        var database = Database()
        database.sleep = Day.range(from: day.adding(days: -10), through: day.adding(days: -1)).enumerated().map { index, d in
            var night = Fixtures.night(day: d, hours: 8)
            // Midpoints alternating either side of midnight: 23:30 and 00:30.
            let offset: TimeInterval = index.isMultiple(of: 2) ? -30 * 60 : 30 * 60
            let midnight = d.startOfDay()
            night.bedtimeStart = midnight.addingTimeInterval(offset - 4 * 3600)
            night.bedtimeEnd = night.bedtimeStart.addingTimeInterval(8 * 3600)
            return night
        }
        let mean = try XCTUnwrap(engine.habitualMidpointHour(before: day, in: database))
        // Must be near 00:00, not near 12:00.
        let distanceToMidnight = min(mean, 24 - mean)
        XCTAssertLessThan(distanceToMidnight, 1.0, "circular mean landed at \(mean)")
    }

    func testFallsBackWhenHistoryIsTooThin() {
        let day = Day(year: 2026, month: 5, day: 20)
        var database = Database()
        database.sleep = [Fixtures.night(day: day.adding(days: -1), hours: 8)]
        XCTAssertNil(engine.habitualMidpointHour(before: day, in: database))
    }

    /// A consistent late sleeper should not be penalised for being consistently late.
    func testConsistentLateSleeperIsNotPunished() throws {
        let day = Day(year: 2026, month: 5, day: 20)
        var database = Database()
        func lateNight(_ d: Day) -> SleepPeriod {
            var night = Fixtures.night(day: d, hours: 7.5)
            // Midpoint at 05:00 rather than the old fixed 03:00 target.
            night.bedtimeStart = d.startOfDay().addingTimeInterval(5 * 3600 - night.timeInBed / 2)
            night.bedtimeEnd = night.bedtimeStart.addingTimeInterval(night.timeInBed)
            return night
        }
        database.sleep = Day.range(from: day.adding(days: -14), through: day).map(lateNight)

        let score = try XCTUnwrap(engine.sleepScore(for: day, in: database))
        let timing = try XCTUnwrap(score.contributors.first { $0.id == "timing" })
        XCTAssertGreaterThan(timing.score, 90, "a consistent schedule should score well wherever it sits")
    }
}

final class NewMetricTests: XCTestCase {
    func testBedtimeWindowConvertsOffsetsFromMidnight() {
        let day = Day(year: 2026, month: 5, day: 20)
        // -3600 is 23:00 the previous evening; 5400 is 01:30.
        let sleepTime = SleepTimeDay(id: "s", day: day, status: "optimal", recommendation: nil,
                                     optimalBedtimeStartOffset: -3600, optimalBedtimeEndOffset: 5400)
        let window = sleepTime.window
        XCTAssertEqual(window?.start, "23:00")
        XCTAssertEqual(window?.end, "01:30")
    }

    func testBedtimeWindowIsNilWithoutBothOffsets() {
        let day = Day(year: 2026, month: 5, day: 20)
        XCTAssertNil(SleepTimeDay(id: "s", day: day, status: nil, recommendation: nil,
                                  optimalBedtimeStartOffset: nil, optimalBedtimeEndOffset: 900).window)
    }

    func testTagCodesBecomeReadableLabels() {
        let tag = DayTag(id: "t", day: Day.today,
                         codes: ["tag_generic_alcohol", "tag_generic_stress"], comment: "one glass", start: nil)
        XCTAssertEqual(tag.labels, ["Alcohol", "Stress"])
    }

    func testResilienceDecodesItsContributors() throws {
        let json = """
        {"data":[{"id":"r1","day":"2026-05-20","level":"strong",
          "contributors":{"sleep_recovery":78.5,"daytime_recovery":66.0,"stress":51.2}}]}
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let page = try decoder.decode(OuraDTO.Page<OuraDTO.DailyResilience>.self, from: Data(json.utf8))
        let mapped = try XCTUnwrap(page.data.first?.map())
        XCTAssertEqual(mapped.level, "strong")
        XCTAssertEqual(mapped.sleepRecovery ?? 0, 78.5, accuracy: 0.001)
        XCTAssertEqual(mapped.daytimeRecovery ?? 0, 66.0, accuracy: 0.001)
    }

    func testCardiovascularAgeDecodes() throws {
        let json = """
        {"data":[{"id":"c1","day":"2026-05-20","vascular_age":31.4}]}
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let page = try decoder.decode(OuraDTO.Page<OuraDTO.DailyCardiovascularAge>.self, from: Data(json.utf8))
        XCTAssertEqual(try XCTUnwrap(page.data.first?.map()).vascularAge ?? 0, 31.4, accuracy: 0.001)
    }

    func testLatestVO2MaxIgnoresEmptyDays() {
        var database = Database()
        database.vo2Max = [
            VO2MaxDay(id: "a", day: Day(year: 2026, month: 5, day: 1), vo2Max: 44.0),
            VO2MaxDay(id: "b", day: Day(year: 2026, month: 5, day: 9), vo2Max: nil)
        ]
        XCTAssertEqual(database.latestVO2Max?.vo2Max, 44.0)
    }
}

/// Guards the fitted `recoveryTime` level. The contributor is a step function rather than a
/// curve, so its levels are easy to change without noticing what else reads them.
final class RecoveryTimeContributorTests: XCTestCase {
    private let engine = ScoreEngine()

    private func recovery(in database: Database, on day: Day) throws -> Contributor {
        let score = try XCTUnwrap(engine.activityScore(for: day, in: database))
        return try XCTUnwrap(score.contributors.first { $0.id == "recoveryTime" })
    }

    func testAWellRecoveredDayScoresTheTopLevel() throws {
        let day = Day(year: 2026, month: 8, day: 8)
        var database = Database()
        // No preceding days, so there is no recent load and nothing to recover from.
        database.activity = [Fixtures.activity(day: day, steps: 9_000, activeCalories: 400)]

        let contributor = try recovery(in: database, on: day)
        XCTAssertEqual(contributor.score, 100, accuracy: 0.001)
        XCTAssertEqual(contributor.detail, "Well recovered")
    }

    func testRecentLoadStillCostsRecoveryPoints() throws {
        let day = Day(year: 2026, month: 8, day: 8)
        var database = Database()
        // The fixture carries 300 MET-minutes a day, so two prior days clear the 500 threshold.
        database.activity = [
            Fixtures.activity(day: day.adding(days: -2), steps: 9_000, activeCalories: 400),
            Fixtures.activity(day: day.adding(days: -1), steps: 9_000, activeCalories: 400),
            Fixtures.activity(day: day, steps: 9_000, activeCalories: 400)
        ]

        let contributor = try recovery(in: database, on: day)
        XCTAssertEqual(contributor.score, 75, accuracy: 0.001)
        XCTAssertEqual(contributor.detail, "Recovery still catching up")
    }

    /// The label is derived from the level, so refitting the level must not orphan it. This
    /// is the assertion that survives a refit: whatever the top level becomes, the day that
    /// reaches it is the day labelled "Well recovered".
    func testTheLabelTracksWhateverTheTopLevelIs() throws {
        let day = Day(year: 2026, month: 8, day: 8)
        var database = Database()
        database.activity = [Fixtures.activity(day: day, steps: 9_000, activeCalories: 400)]
        let unloaded = try recovery(in: database, on: day)

        database.activity = [
            Fixtures.activity(day: day.adding(days: -2), steps: 9_000, activeCalories: 400),
            Fixtures.activity(day: day.adding(days: -1), steps: 9_000, activeCalories: 400),
            Fixtures.activity(day: day, steps: 9_000, activeCalories: 400)
        ]
        let loaded = try recovery(in: database, on: day)

        XCTAssertGreaterThan(unloaded.score, loaded.score)
        XCTAssertEqual(unloaded.detail, "Well recovered")
        XCTAssertEqual(loaded.detail, "Recovery still catching up")
    }
}
