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
        XCTAssertGreaterThan(hitScore.value, missedScore.value + 20)
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
        hrv: Double = 60
    ) -> SleepPeriod {
        let total = hours * 3600
        // Bedtime chosen so the midpoint lands near 03:00, the engine's ideal.
        let start = day.startOfDay().addingTimeInterval(3 * 3600 - total / 2)
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
