import Foundation

/// Pulls a date range from Oura and merges it into the local database.
struct SyncEngine {
    let store: LocalStore

    /// How far back the very first sync reaches. Two weeks is the minimum for useful
    /// baselines, so the default gives plenty of runway.
    static let initialBackfillDays = 180
    /// Recent days are re-fetched every sync because Oura revises the last night or two.
    static let refreshWindowDays = 14

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

        let sleep = try await sleepTask
        let activity = try await activityTask
        let readiness = try await readinessTask

        // Optional endpoints: keep syncing even when the account has nothing for them.
        let dailySleepScores = (try? await client.dailySleep(from: start, to: today)) ?? [:]
        let spo2 = try? await client.spo2(from: start, to: today)
        let stress = try? await client.stress(from: start, to: today)
        let workouts = try? await client.workouts(from: start, to: today)
        let personalInfo = try? await client.personalInfo()

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
            workouts: workouts ?? []
        )
        database.applyCloudSleepScores(dailySleepScores)
        if let personalInfo { database.personalInfo = personalInfo }
        database.lastSync = Date()
        database.earliestSynced = min(database.earliestSynced ?? start, start)

        try await store.save(database)
        return Result(database: database, warnings: warnings)
    }
}
