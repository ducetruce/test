import Foundation

#if DEBUG
/// Synthetic 14-day database for local visual QA in the simulator, where the app can never
/// have a real Keychain entitlement — see the note on `Theme.tabBarClearance`'s neighbours in
/// CLAUDE.md for why. `AppModel.loadPreviewFixtures()` is the only thing that reads this, and
/// it only runs behind the `--preview-fixtures` launch argument gated in `OpenRingApp.swift`,
/// so this can't leak into a real build by accident.
///
/// Day `-4` is left with no sleep or activity record on purpose: it is the only way, short of
/// a real account, to see the app's actual empty states rather than infer them from source.
///
/// Spans 46 days, not 14: the day strip used to hardcode a 14-day window regardless of how
/// much history existed (see `Database.dayStripDays`), and a 14-day fixture can never show
/// whether that's actually fixed. 46 also gives Trends' 30-day view real width to plot.
enum PreviewFixtures {
    static var database: Database {
        var db = Database()
        let today = Day.today
        let gapDayOffset = -4

        for offset in -45...0 {
            let day = today.adding(days: offset)
            guard offset != gapDayOffset else { continue }

            // Deterministic but varied, so the charts and day strip have real shape to look at
            // rather than a flat line — a fixed function of the offset, not randomness, so a
            // second run looks the same as the first.
            let hours = 6.0 + Double(abs(offset * 37) % 25) / 10 // 6.0 ... 8.4
            let efficiency = 80.0 + Double(abs(offset * 13) % 18) // 80 ... 97
            let steps = 3000 + (abs(offset) * 619) % 9000
            let activeCal = 150.0 + Double(abs(offset * 71) % 400)

            db.sleep.append(sleepPeriod(day: day, hours: hours, efficiency: efficiency))
            db.activity.append(activityDay(day: day, steps: steps, activeCalories: activeCal))
            db.readiness.append(
                ReadinessDay(
                    id: "readiness-\(day)",
                    day: day,
                    cloudScore: nil,
                    temperatureDeviation: Double(abs(offset * 3) % 7) / 10 - 0.3,
                    temperatureTrendDeviation: nil
                )
            )
        }
        return db
    }

    private static func sleepPeriod(day: Day, hours: Double, efficiency: Double) -> SleepPeriod {
        let total = hours * 3600
        let start = day.startOfDay().addingTimeInterval(3 * 3600 - total / 2)
        let timeInBed = total / (efficiency / 100)
        return SleepPeriod(
            id: "sleep-\(day)",
            day: day,
            bedtimeStart: start,
            bedtimeEnd: start.addingTimeInterval(timeInBed),
            type: "long_sleep",
            timeInBed: timeInBed,
            totalSleep: total,
            deep: total * 0.18,
            light: total * 0.53,
            rem: total * 0.21,
            awake: total * 0.08,
            latency: 12 * 60,
            efficiency: efficiency,
            restlessPeriods: 18,
            averageHeartRate: 58,
            lowestHeartRate: 52,
            averageHRV: 42,
            averageBreath: 14.1,
            stages: [],
            heartRate: nil,
            hrv: nil,
            cloudScore: nil
        )
    }

    private static func activityDay(day: Day, steps: Int, activeCalories: Double) -> ActivityDay {
        ActivityDay(
            id: "activity-\(day)",
            day: day,
            steps: steps,
            activeCalories: activeCalories,
            totalCalories: activeCalories + 1750,
            targetCalories: 500,
            equivalentWalkingDistance: Double(steps) * 0.75,
            highActivityMinutes: 12,
            mediumActivityMinutes: 30,
            lowActivityMinutes: 140,
            sedentaryTime: 7 * 3600,
            restingTime: 8 * 3600,
            nonWearTime: 0,
            inactivityAlerts: 1,
            highActivityMET: 90,
            mediumActivityMET: 150,
            lowActivityMET: 180,
            averageMET: 1.5,
            classes: [],
            met: nil,
            cloudScore: nil
        )
    }
}
#endif
