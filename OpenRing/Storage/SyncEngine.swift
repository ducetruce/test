import Foundation

/// Pulls a date range from Oura and merges it into the local database.
struct SyncEngine {
    let store: LocalStore

    /// How far back the very first sync reaches. Two weeks is the minimum for useful
    /// baselines, so the default gives plenty of runway.
    static let initialBackfillDays = 180
    /// Recent days are re-fetched every sync because Oura revises the last night or two.
    static let refreshWindowDays = 14

    private static func report(_ endpoint: String, _ from: Day, _ to: Day, _ days: [Day]) -> EndpointReport {
        EndpointReport(
            endpoint: endpoint, requestedFrom: from, requestedTo: to,
            received: days.count, newestDay: days.max(),
            missingToday: !days.contains(to)
        )
    }

    struct Result {
        var database: Database
        /// Endpoints that failed but were not fatal (an account without SpO2 data, say).
        var warnings: [String]
    }

    func sync(using tokens: OuraTokenProviding, fullHistory: Bool = false) async throws -> Result {
        var database = await store.load()
        let today = Day.today
        let start: Day
        if fullHistory || database.isEmpty {
            start = today.adding(days: -Self.initialBackfillDays)
        } else if let earliest = database.earliestSynced, database.lastSync != nil {
            start = max(earliest, today.adding(days: -Self.refreshWindowDays))
        } else {
            start = today.adding(days: -Self.initialBackfillDays)
        }

        let client = OuraClient(tokens: tokens)
        var warnings: [String] = []

        // Core endpoints: a failure here is a real failure worth surfacing.
        async let sleepTask = client.sleepPeriods(from: start, to: today)
        async let activityTask = client.activity(from: start, to: today)
        async let readinessTask = client.readiness(from: start, to: today)

        var sleep = try await sleepTask
        var activity = try await activityTask
        let readiness = try await readinessTask

        // If the main window came back without today, ask again for just today with the end
        // date pushed out a day. That covers an exclusive end_date and a record published
        // between the two requests. Wrapped in try? so it can never break a working sync —
        // a server that rejects a future end_date simply yields nothing here.
        if !sleep.contains(where: { $0.day == today }) {
            if let late = try? await client.sleepPeriods(from: today.adding(days: -1), to: today.adding(days: 1)) {
                sleep.append(contentsOf: late)
            }
        }
        if !activity.contains(where: { $0.day == today }) {
            if let late = try? await client.activity(from: today.adding(days: -1), to: today.adding(days: 1)) {
                activity.append(contentsOf: late)
            }
        }

        // Optional endpoints: keep syncing even when the account has nothing for them.
        let dailySleepScores = (try? await client.dailySleep(from: start, to: today)) ?? [:]
        let spo2 = try? await client.spo2(from: start, to: today)
        let stress = try? await client.stress(from: start, to: today)
        let workouts = try? await client.workouts(from: start, to: today)
        let personalInfo = try? await client.personalInfo()

        // Newer metrics. Not every account or ring generation returns these, and a plan
        // that lacks one should not fail the whole sync, so each is independently optional.
        let cardiovascularAge = try? await client.cardiovascularAge(from: start, to: today)
        let resilience = try? await client.resilience(from: start, to: today)
        let vo2Max = try? await client.vo2Max(from: start, to: today)
        let sleepTimes = try? await client.sleepTime(from: start, to: today)
        let sessions = try? await client.sessions(from: start, to: today)
        let tags = try? await client.tags(from: start, to: today)
        let restModes = try? await client.restModePeriods(from: start, to: today)
        let ringInfo = try? await client.ringInfo()

        for (name, missing) in [("Cardiovascular age", cardiovascularAge == nil),
                                ("Resilience", resilience == nil),
                                ("VO2 max", vo2Max == nil),
                                ("Bedtime guidance", sleepTimes == nil),
                                ("Guided sessions", sessions == nil),
                                ("Tags", tags == nil),
                                ("Ring details", ringInfo == nil)] where missing {
            warnings.append("\(name) unavailable on this account")
        }

        if spo2 == nil { warnings.append("Blood oxygen data unavailable") }
        if stress == nil { warnings.append("Daytime stress data unavailable") }
        if workouts == nil { warnings.append("Workout data unavailable") }
        if dailySleepScores.isEmpty { warnings.append("Oura returned no cloud sleep scores — using locally computed scores only") }

        database.merge(
            sleep: sleep,
            activity: activity,
            readiness: readiness,
            spo2: spo2 ?? [],
            stress: stress ?? [],
            workouts: workouts ?? [],
            cardiovascularAge: cardiovascularAge ?? [],
            resilience: resilience ?? [],
            vo2Max: vo2Max ?? [],
            sleepTimes: sleepTimes ?? [],
            sessions: sessions ?? [],
            tags: tags ?? [],
            restModePeriods: restModes ?? []
        )
        if let ringInfo { database.ringInfo = ringInfo }
        database.applyCloudSleepScores(dailySleepScores)
        if let personalInfo { database.personalInfo = personalInfo }
        database.lastSyncReports = [
            Self.report("sleep", start, today, sleep.map(\.day)),
            Self.report("daily_activity", start, today, activity.map(\.day)),
            Self.report("daily_readiness", start, today, readiness.map(\.day)),
            Self.report("daily_spo2", start, today, (spo2 ?? []).map(\.day)),
            Self.report("daily_stress", start, today, (stress ?? []).map(\.day)),
            Self.report("workout", start, today, (workouts ?? []).map(\.day))
        ]
        database.lastSync = Date()
        database.earliestSynced = min(database.earliestSynced ?? start, start)

        try await store.save(database)
        return Result(database: database, warnings: warnings)
    }
}
