import Foundation

/// Computes Sleep, Readiness and Activity scores entirely on-device from the raw signals
/// the ring records (sleep staging, heart rate, HRV, temperature deviation, MET minutes).
///
/// The curves below are a transparent re-implementation in the spirit of Oura's published
/// contributor list — they are *not* Oura's proprietary formulas, so absolute numbers will
/// differ by a few points. What matters for day-to-day use is that they are consistent and
/// keep working whether or not the cloud returns a score.
struct ScoreEngine {

    struct Baselines {
        var restingHeartRate: Double?
        var hrv: Double?
        var sleepHours: Double?
        var activeCalories: Double?
        var trainingMETMinutes: Double?
    }

    /// How much sleep the model treats as "a full night" for balance calculations.
    var sleepNeedHours: Double = 7.5
    /// Ideal sleep midpoint, as an hour of the day (3.0 == 03:00).
    var idealMidpointHour: Double = 3.0
    /// Weekly training target in MET-minutes of medium+high activity.
    var weeklyMETMinuteTarget: Double = 2000

    // MARK: - Entry points

    func scores(for day: Day, in database: Database) -> DayScores {
        let sleepScore = sleepScore(for: day, in: database)
        return DayScores(
            day: day,
            sleep: sleepScore,
            readiness: readinessScore(for: day, in: database, sleepScore: sleepScore),
            activity: activityScore(for: day, in: database)
        )
    }

    func allScores(in database: Database) -> [Day: DayScores] {
        guard let range = database.dayRange else { return [:] }
        var result: [Day: DayScores] = [:]
        for day in Day.range(from: range.first, through: range.last) {
            let scores = scores(for: day, in: database)
            if scores.sleep != nil || scores.readiness != nil || scores.activity != nil {
                result[day] = scores
            }
        }
        return result
    }

    // MARK: - Sleep

    func sleepScore(for day: Day, in database: Database) -> Score? {
        guard let night = database.mainSleep(on: day), night.totalSleep > 0 else { return nil }

        let hours = night.totalSleep / 3600
        var contributors: [Contributor] = []

        contributors.append(Contributor(
            id: "total",
            label: "Total sleep",
            score: Curve.score(hours, [(3, 10), (5, 50), (6, 75), (7, 95), (7.5, 100), (9, 100), (10, 85), (12, 60)]),
            weight: 0.22,
            detail: Format.duration(night.totalSleep)
        ))

        let efficiency = night.efficiency ?? (night.timeInBed > 0 ? night.totalSleep / night.timeInBed * 100 : 0)
        contributors.append(Contributor(
            id: "efficiency",
            label: "Efficiency",
            score: Curve.score(efficiency, [(60, 10), (75, 50), (85, 80), (90, 95), (95, 100), (100, 100)]),
            weight: 0.12,
            detail: "\(Int(efficiency.rounded()))% asleep in bed"
        ))

        // Restfulness: restless periods per hour, falling back to awake time when the ring
        // did not report movement counts.
        let restlessness = night.restlessPeriodsPerHour
            ?? (night.totalSleep > 0 ? night.awake / night.totalSleep * 60 : 20)
        contributors.append(Contributor(
            id: "restfulness",
            label: "Restfulness",
            score: Curve.score(restlessness, [(0, 100), (5, 95), (10, 80), (20, 55), (35, 25), (50, 5)]),
            weight: 0.14,
            detail: night.restlessPeriods.map { "\($0) restless periods" } ?? Format.duration(night.awake) + " awake"
        ))

        let remShare = night.totalSleep > 0 ? night.rem / night.totalSleep * 100 : 0
        contributors.append(Contributor(
            id: "rem",
            label: "REM sleep",
            score: Curve.score(remShare, [(5, 20), (10, 55), (15, 80), (20, 95), (22, 100), (30, 100), (35, 85), (45, 60)]),
            weight: 0.14,
            detail: "\(Format.duration(night.rem)) (\(Int(remShare.rounded()))%)"
        ))

        let deepShare = night.totalSleep > 0 ? night.deep / night.totalSleep * 100 : 0
        contributors.append(Contributor(
            id: "deep",
            label: "Deep sleep",
            score: Curve.score(deepShare, [(3, 15), (8, 50), (12, 80), (15, 95), (18, 100), (25, 100), (32, 85)]),
            weight: 0.14,
            detail: "\(Format.duration(night.deep)) (\(Int(deepShare.rounded()))%)"
        ))

        let latencyMinutes = (night.latency ?? 900) / 60
        contributors.append(Contributor(
            id: "latency",
            label: "Latency",
            score: Curve.score(latencyMinutes, [(0, 80), (5, 95), (10, 100), (20, 100), (30, 85), (45, 60), (60, 40), (90, 15)]),
            weight: 0.10,
            detail: "\(Int(latencyMinutes.rounded())) min to fall asleep"
        ))

        let midpointDeviation = midpointDeviationHours(for: night)
        contributors.append(Contributor(
            id: "timing",
            label: "Timing",
            score: Curve.score(midpointDeviation, [(0, 100), (0.5, 100), (1, 95), (2, 80), (3, 55), (4, 30), (6, 10)]),
            weight: 0.14,
            detail: "Midpoint \(Format.clockTime(night.midpoint))"
        ))

        return Score(
            kind: .sleep,
            value: weightedScore(contributors),
            contributors: contributors,
            cloudValue: night.cloudScore
        )
    }

    /// Distance in hours between the night's midpoint and the ideal midpoint, measured
    /// around the clock so 23:00 and 01:00 are 2 hours apart, not 22.
    private func midpointDeviationHours(for night: SleepPeriod) -> Double {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.hour, .minute], from: night.midpoint)
        let hour = Double(components.hour ?? 0) + Double(components.minute ?? 0) / 60
        var difference = abs(hour - idealMidpointHour)
        if difference > 12 { difference = 24 - difference }
        return difference
    }

    // MARK: - Readiness

    func readinessScore(for day: Day, in database: Database, sleepScore: Score?) -> Score? {
        let night = database.mainSleep(on: day)
        let readiness = database.readinessDay(day)
        // Without a night of data there is nothing to recover from.
        guard night != nil || readiness != nil else { return nil }

        let personal = baselines(before: day, in: database)
        var contributors: [Contributor] = []

        if let rhr = night?.lowestHeartRate, let baseline = personal.restingHeartRate {
            let delta = rhr - baseline
            contributors.append(Contributor(
                id: "rhr",
                label: "Resting heart rate",
                score: Curve.score(delta, [(-8, 100), (-3, 100), (0, 97), (2, 88), (4, 72), (7, 45), (12, 15)]),
                weight: 0.18,
                detail: "\(Int(rhr.rounded())) bpm vs \(Int(baseline.rounded())) baseline"
            ))
        } else if let rhr = night?.lowestHeartRate {
            contributors.append(Contributor(
                id: "rhr",
                label: "Resting heart rate",
                score: 90,
                weight: 0.18,
                detail: "\(Int(rhr.rounded())) bpm — building baseline"
            ))
        }

        if let hrv = night?.averageHRV, let baseline = personal.hrv, baseline > 0 {
            let ratio = hrv / baseline
            contributors.append(Contributor(
                id: "hrv",
                label: "HRV balance",
                score: Curve.score(ratio, [(0.6, 15), (0.75, 40), (0.85, 65), (0.95, 85), (1.0, 92), (1.1, 100), (1.4, 100)]),
                weight: 0.20,
                detail: "\(Int(hrv.rounded())) ms vs \(Int(baseline.rounded())) baseline"
            ))
        } else if let hrv = night?.averageHRV {
            contributors.append(Contributor(
                id: "hrv",
                label: "HRV balance",
                score: 90,
                weight: 0.20,
                detail: "\(Int(hrv.rounded())) ms — building baseline"
            ))
        }

        if let deviation = readiness?.temperatureDeviation {
            contributors.append(Contributor(
                id: "temperature",
                label: "Body temperature",
                score: Curve.score(abs(deviation), [(0, 100), (0.2, 97), (0.4, 85), (0.6, 65), (0.9, 40), (1.5, 10)]),
                weight: 0.14,
                detail: String(format: "%+.2f °C from baseline", deviation)
            ))
        }

        if let sleepScore {
            contributors.append(Contributor(
                id: "previousNight",
                label: "Previous night",
                score: Double(sleepScore.value),
                weight: 0.18,
                detail: "Sleep score \(sleepScore.value)"
            ))
        }

        if let baseline = personal.sleepHours {
            let ratio = baseline / sleepNeedHours
            contributors.append(Contributor(
                id: "sleepBalance",
                label: "Sleep balance",
                score: Curve.score(ratio, [(0.6, 25), (0.75, 55), (0.85, 75), (0.95, 92), (1.0, 100), (1.2, 100)]),
                weight: 0.12,
                detail: String(format: "%.1f h/night over two weeks", baseline)
            ))
        }

        if let recent = trailingMean(of: { database.activityDay($0)?.trainingMETMinutes }, endingBefore: day, days: 7),
           let baseline = personal.trainingMETMinutes, baseline > 0 {
            let ratio = recent / baseline
            contributors.append(Contributor(
                id: "activityBalance",
                label: "Activity balance",
                score: Curve.score(ratio, [(0.4, 70), (0.7, 90), (1.0, 100), (1.3, 85), (1.6, 60), (2.0, 35)]),
                weight: 0.08,
                detail: ratio > 1.2 ? "Training load rising" : (ratio < 0.7 ? "Training load falling" : "Training load steady")
            ))
        }

        if let previousActivity = database.activityDay(day.adding(days: -1)) {
            let load = previousActivity.trainingMETMinutes
            contributors.append(Contributor(
                id: "previousDayActivity",
                label: "Previous day activity",
                score: Curve.score(load, [(0, 85), (50, 100), (150, 100), (300, 80), (500, 55), (800, 30)]),
                weight: 0.05,
                detail: "\(Int(load.rounded())) MET-min yesterday"
            ))
        }

        if let position = night?.heartRate?.minimumPosition {
            contributors.append(Contributor(
                id: "recoveryIndex",
                label: "Recovery index",
                score: Curve.score(position, [(0.2, 100), (0.35, 95), (0.5, 80), (0.65, 60), (0.8, 35), (1.0, 15)]),
                weight: 0.05,
                detail: position < 0.5 ? "Heart rate settled early" : "Heart rate settled late"
            ))
        }

        guard !contributors.isEmpty else { return nil }
        return Score(
            kind: .readiness,
            value: weightedScore(contributors),
            contributors: contributors,
            cloudValue: readiness?.cloudScore
        )
    }

    // MARK: - Activity

    func activityScore(for day: Day, in database: Database) -> Score? {
        guard let activity = database.activityDay(day) else { return nil }
        var contributors: [Contributor] = []

        let sedentaryHours = activity.sedentaryTime / 3600
        contributors.append(Contributor(
            id: "stayActive",
            label: "Stay active",
            score: Curve.score(sedentaryHours, [(4, 100), (6, 95), (8, 80), (10, 60), (12, 35), (14, 15)]),
            weight: 0.18,
            detail: String(format: "%.1f h sedentary", sedentaryHours)
        ))

        contributors.append(Contributor(
            id: "moveEveryHour",
            label: "Move every hour",
            score: Curve.score(Double(activity.inactivityAlerts), [(0, 100), (1, 92), (2, 80), (3, 65), (5, 40), (8, 15)]),
            weight: 0.12,
            detail: "\(activity.inactivityAlerts) inactivity alerts"
        ))

        let target = activity.targetCalories > 0 ? activity.targetCalories : 400
        let ratio = activity.activeCalories / target
        contributors.append(Contributor(
            id: "dailyTargets",
            label: "Meet daily targets",
            score: Curve.score(ratio, [(0.2, 20), (0.5, 55), (0.8, 85), (1.0, 100), (1.5, 100), (2.0, 90)]),
            weight: 0.28,
            detail: "\(Int(activity.activeCalories.rounded())) / \(Int(target.rounded())) active kcal"
        ))

        let trainingDays = Day.range(from: day.adding(days: -6), through: day)
            .compactMap { database.activityDay($0) }
            .filter { $0.highActivityMinutes + $0.mediumActivityMinutes >= 20 }
            .count
        contributors.append(Contributor(
            id: "trainingFrequency",
            label: "Training frequency",
            score: Curve.score(Double(trainingDays), [(0, 20), (1, 45), (2, 65), (3, 85), (4, 95), (5, 100), (7, 100)]),
            weight: 0.16,
            detail: "\(trainingDays) active days this week"
        ))

        let weeklyMET = Day.range(from: day.adding(days: -6), through: day)
            .compactMap { database.activityDay($0)?.trainingMETMinutes }
            .reduce(0, +)
        contributors.append(Contributor(
            id: "trainingVolume",
            label: "Training volume",
            score: Curve.score(weeklyMET / weeklyMETMinuteTarget, [(0.2, 25), (0.5, 60), (0.8, 88), (1.0, 100), (1.6, 100), (2.2, 80)]),
            weight: 0.18,
            detail: "\(Int(weeklyMET.rounded())) MET-min over 7 days"
        ))

        // Recovery time: a hard block of training right before a poor night is the one case
        // where doing more should *cost* activity points.
        let recentLoad = Day.range(from: day.adding(days: -2), through: day.adding(days: -1))
            .compactMap { database.activityDay($0)?.trainingMETMinutes }
            .reduce(0, +)
        let lastNightScore = sleepScore(for: day, in: database)?.value ?? 80
        let recoveryScore: Double
        if recentLoad > 500 && lastNightScore < 70 {
            recoveryScore = 45
        } else if recentLoad > 500 || lastNightScore < 70 {
            recoveryScore = 75
        } else {
            recoveryScore = 100
        }
        contributors.append(Contributor(
            id: "recoveryTime",
            label: "Recovery time",
            score: recoveryScore,
            weight: 0.08,
            detail: recoveryScore == 100 ? "Well recovered" : "Recovery still catching up"
        ))

        return Score(
            kind: .activity,
            value: weightedScore(contributors),
            contributors: contributors,
            cloudValue: activity.cloudScore
        )
    }

    // MARK: - Baselines

    /// Personal baselines from the trailing window before `day`. Everything is relative to
    /// the wearer, which is why the app needs a couple of weeks of history to be useful.
    func baselines(before day: Day, in database: Database) -> Baselines {
        Baselines(
            restingHeartRate: trailingMedian(of: { database.mainSleep(on: $0)?.lowestHeartRate }, endingBefore: day, days: 14),
            hrv: trailingMedian(of: { database.mainSleep(on: $0)?.averageHRV }, endingBefore: day, days: 14),
            sleepHours: trailingMean(of: { database.mainSleep(on: $0).map { $0.totalSleep / 3600 } }, endingBefore: day, days: 14),
            activeCalories: trailingMean(of: { database.activityDay($0)?.activeCalories }, endingBefore: day, days: 28),
            trainingMETMinutes: trailingMean(of: { database.activityDay($0)?.trainingMETMinutes }, endingBefore: day, days: 28)
        )
    }

    private func trailingValues(
        of value: (Day) -> Double?,
        endingBefore day: Day,
        days: Int
    ) -> [Double] {
        Day.range(from: day.adding(days: -days), through: day.adding(days: -1)).compactMap(value)
    }

    private func trailingMedian(of value: (Day) -> Double?, endingBefore day: Day, days: Int) -> Double? {
        let samples = trailingValues(of: value, endingBefore: day, days: days)
        guard samples.count >= 3 else { return nil }
        return Stats.median(samples)
    }

    private func trailingMean(of value: (Day) -> Double?, endingBefore day: Day, days: Int) -> Double? {
        let samples = trailingValues(of: value, endingBefore: day, days: days)
        guard samples.count >= 3 else { return nil }
        return Stats.mean(samples)
    }

    // MARK: - Combining

    /// Weighted mean of whichever contributors are available, renormalised so a missing
    /// signal (no temperature that night, say) does not silently drag the score down.
    private func weightedScore(_ contributors: [Contributor]) -> Int {
        let totalWeight = contributors.reduce(0) { $0 + $1.weight }
        guard totalWeight > 0 else { return 0 }
        let sum = contributors.reduce(0) { $0 + Curve.clamp($1.score) * $1.weight }
        return Int(Curve.clamp(sum / totalWeight, 1...100).rounded())
    }
}
