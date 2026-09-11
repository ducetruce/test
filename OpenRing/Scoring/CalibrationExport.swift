import Foundation

/// Emits the paired data needed to retune the scoring curves: for each day, this app's
/// score, Oura's score for the same day, and the raw inputs that produced ours.
///
/// Deliberately narrow. Comparing two scores alone can only fit a global offset — it cannot
/// say *which* contributor is mis-shaped — so the inputs are included. Nothing identifying
/// is: no email, no age, weight or height, no heart-rate or HRV time series, no workouts,
/// no bedtimes. Just the numbers a curve is fitted against.
enum CalibrationExport {

    static let columns = [
        "day",
        "sleep_coverage", "sleep_mine", "sleep_oura",
        "hours", "efficiency", "deep_pct", "rem_pct", "latency_min", "restless_per_hr", "midpoint_dev_hr",
        "readiness_coverage", "readiness_mine", "readiness_oura",
        "rhr", "rhr_baseline", "hrv", "hrv_baseline", "temp_dev",
        "activity_coverage", "activity_mine", "activity_oura",
        "steps", "active_cal", "target_cal", "sedentary_hr", "inactivity_alerts", "met_minutes",
        // `trainingFrequency` counts days whose high+medium minutes clear a threshold, so the
        // daily minutes have to be here or that contributor cannot be fitted at all — only
        // guessed at. Appended rather than grouped so existing column offsets do not move.
        "high_activity_min", "medium_activity_min",
        // `recoveryIndex` (readiness) reads where in the night the heart rate bottomed out;
        // same reasoning as the two above — it was never exportable, so it was never fitted.
        "hr_minimum_position"
    ]

    /// `warmUpDays` skips the span where trailing baselines have not filled yet; those
    /// days score differently for reasons that have nothing to do with the curves.
    static func csv(
        database: Database,
        scores: [Day: DayScores],
        engine: ScoreEngine = ScoreEngine(),
        warmUpDays: Int = 28
    ) -> String {
        guard let range = database.dayRange else { return columns.joined(separator: ",") + "\n" }
        let firstUsable = range.first.adding(days: warmUpDays)

        var rows = [columns.joined(separator: ",")]
        for day in Day.range(from: firstUsable, through: range.last) {
            guard let dayScores = scores[day] else { continue }
            // A day with none of the three scored carries no information.
            if dayScores.sleep == nil && dayScores.readiness == nil && dayScores.activity == nil { continue }

            let night = database.mainSleep(on: day)
            let activity = database.activityDay(day)
            let readiness = database.readinessDay(day)
            let baselines = engine.baselines(before: day, in: database)

            var row: [String] = [day.description]

            row += [
                number(dayScores.sleep?.coverage, 2),
                integer(dayScores.sleep?.value),
                integer(night?.cloudScore),
                number(night.map { $0.totalSleep / 3600 }, 2),
                number(night?.efficiency, 1),
                number(share(night?.deep, of: night?.totalSleep), 1),
                number(share(night?.rem, of: night?.totalSleep), 1),
                number(night?.latency.map { $0 / 60 }, 1),
                number(night?.restlessPeriodsPerHour, 2),
                number(night.map { midpointDeviationHours(for: $0, in: database, engine: engine) }, 2)
            ]

            row += [
                number(dayScores.readiness?.coverage, 2),
                integer(dayScores.readiness?.value),
                integer(readiness?.cloudScore),
                number(night?.lowestHeartRate, 1),
                number(baselines.restingHeartRate, 1),
                number(night?.averageHRV, 1),
                number(baselines.hrv, 1),
                number(readiness?.temperatureDeviation, 2)
            ]

            row += [
                number(dayScores.activity?.coverage, 2),
                integer(dayScores.activity?.value),
                integer(activity?.cloudScore),
                integer(activity?.steps),
                number(activity?.activeCalories, 0),
                number(activity?.targetCalories, 0),
                number(activity.map { $0.sedentaryTime / 3600 }, 2),
                integer(activity?.inactivityAlerts),
                number(activity?.trainingMETMinutes, 0),
                number(activity?.highActivityMinutes, 0),
                number(activity?.mediumActivityMinutes, 0),
                number(night?.heartRate?.minimumPosition, 3)
            ]

            rows.append(row.joined(separator: ","))
        }
        return rows.joined(separator: "\n") + "\n"
    }

    /// Rows where every score is complete — the only ones worth fitting against.
    static func completeDayCount(scores: [Day: DayScores]) -> Int {
        scores.values.filter { day in
            [day.sleep, day.readiness, day.activity].allSatisfy { $0 == nil || $0?.isPartial == false }
                && day.sleep != nil
        }.count
    }

    // MARK: - Formatting

    private static func share(_ part: TimeInterval?, of whole: TimeInterval?) -> Double? {
        guard let part, let whole, whole > 0 else { return nil }
        return part / whole * 100
    }

    /// Was a standalone copy with a hard-coded 3am reference, which silently diverged from
    /// what `sleepScore`'s `timing` contributor actually reads — the personal rolling
    /// midpoint, once 5 nights of history exist. A row's exported `midpoint_dev_hr` could be
    /// off by as much as the personal baseline had drifted from 3am, which for anyone whose
    /// habitual midpoint isn't there is most of the scale: on this app's own 154-day export
    /// the two disagreed enough to imply a timing score up to ~46 points different, one-sided.
    /// Delegating to the engine's `habitualMidpointHour` makes divergence structurally
    /// impossible instead of relying on the two copies being kept in sync by hand.
    private static func midpointDeviationHours(for night: SleepPeriod, in database: Database, engine: ScoreEngine) -> Double {
        let reference = engine.habitualMidpointHour(before: night.day, in: database) ?? engine.fallbackMidpointHour
        var difference = abs(engine.hourOfDay(night.midpoint) - reference)
        if difference > 12 { difference = 24 - difference }
        return difference
    }

    /// Empty rather than 0 for missing values: a zero would be fitted as a real measurement.
    private static func number(_ value: Double?, _ decimals: Int) -> String {
        guard let value else { return "" }
        return String(format: "%.\(decimals)f", value)
    }

    private static func integer(_ value: Int?) -> String {
        guard let value else { return "" }
        return "\(value)"
    }
}
