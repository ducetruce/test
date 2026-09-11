import Foundation

/// Pulls a date range from Oura and merges it into the local database.
struct SyncEngine {
    let store: LocalStore

    /// How far back the very first sync reaches. Two weeks is the minimum for useful
    /// baselines, so the default gives plenty of runway.
    static let initialBackfillDays = 180
    /// Recent days are re-fetched every sync because Oura revises the last night or two.
    static let refreshWindowDays = 14

    private static func report(
        _ endpoint: String, _ from: Day, _ to: Day, _ days: [Day],
        isDaily: Bool = true, failure: String? = nil
    ) -> EndpointReport {
        EndpointReport(
            endpoint: endpoint, requestedFrom: from, requestedTo: to,
            received: days.count, newestDay: days.max(),
            isDaily: isDaily, failure: failure,
            missingToday: isDaily && !days.contains(to)
        )
    }

    /// Runs an optional endpoint, keeping *why* it failed instead of discarding it.
    /// "Unavailable on this account" reads like a bug; an HTTP status says whether the
    /// endpoint is missing, forbidden, or simply not part of this plan.
    private func optional<T>(_ work: () async throws -> T) async -> (value: T?, failure: String?) {
        do {
            return (try await work(), nil)
        } catch {
            return (nil, (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
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
        let (cardiovascularAge, cvaFailure) = await optional { try await client.cardiovascularAge(from: start, to: today) }
        let (resilience, resilienceFailure) = await optional { try await client.resilience(from: start, to: today) }
        let (vo2Max, vo2Failure) = await optional { try await client.vo2Max(from: start, to: today) }
        let (sleepTimes, sleepTimeFailure) = await optional { try await client.sleepTime(from: start, to: today) }
        let (sessions, sessionFailure) = await optional { try await client.sessions(from: start, to: today) }
        let (tags, tagFailure) = await optional { try await client.tags(from: start, to: today) }
        let (restModes, _) = await optional { try await client.restModePeriods(from: start, to: today) }
        let (ringInfo, ringFailure) = await optional { try await client.ringInfo() }

        for (name, failure) in [("Cardiovascular age", cvaFailure), ("Resilience", resilienceFailure),
                                ("VO2 max", vo2Failure), ("Bedtime guidance", sleepTimeFailure),
                                ("Guided sessions", sessionFailure), ("Tags", tagFailure),
                                ("Ring details", ringFailure)] {
            if let failure { warnings.append("\(name): \(failure)") }
        }

        // An endpoint that answers with an empty list has not failed; the record count in
        // the report already says so, and a warning here would imply a fault that is not one.
        if spo2 == nil { warnings.append("Blood oxygen: request failed") }
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
        // Several endpoints rejecting a token that a dozen others accept is not a broken
        // sign-in, whatever the status code says. Saying so beats an error that sends the
        // user to re-authorise for something re-authorising cannot fix.
        let rejected = [cvaFailure, resilienceFailure, vo2Failure, ringFailure]
            .compactMap { $0 }
            .filter { $0.contains("rejected the credentials") }
        if !rejected.isEmpty {
            warnings.append(
                "\(rejected.count) metric(s) were refused while the rest of the sync succeeded — "
                + "the sign-in is working, so these are almost certainly not included in your Oura plan."
            )
        }

        database.lastSyncReports = [
            Self.report("sleep", start, today, sleep.map(\.day)),
            Self.report("daily_activity", start, today, activity.map(\.day)),
            Self.report("daily_readiness", start, today, readiness.map(\.day)),
            Self.report("daily_spo2", start, today, (spo2 ?? []).map(\.day)),
            Self.report("daily_stress", start, today, (stress ?? []).map(\.day)),
            // Event-based: a gap is a quiet week, not a fault.
            Self.report("workout", start, today, (workouts ?? []).map(\.day), isDaily: false),
            Self.report("session", start, today, (sessions ?? []).map(\.day), isDaily: false, failure: sessionFailure),
            Self.report("tag", start, today, (tags ?? []).map(\.day), isDaily: false, failure: tagFailure),
            Self.report("daily_cardiovascular_age", start, today, (cardiovascularAge ?? []).map(\.day), failure: cvaFailure),
            Self.report("daily_resilience", start, today, (resilience ?? []).map(\.day), failure: resilienceFailure),
            Self.report("vO2_max", start, today, (vo2Max ?? []).map(\.day), isDaily: false, failure: vo2Failure),
            // Bedtime guidance is recomputed periodically rather than daily — 149 records
            // across roughly 180 days, newest often a couple of days back — so a gap here
            // is not a fault either.
            Self.report("sleep_time", start, today, (sleepTimes ?? []).map(\.day), isDaily: false, failure: sleepTimeFailure)
        ]
        database.lastSync = Date()
        database.earliestSynced = min(database.earliestSynced ?? start, start)

        try await store.save(database)
        return Result(database: database, warnings: warnings)
    }
}
