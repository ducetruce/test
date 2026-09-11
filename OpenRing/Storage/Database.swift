import Foundation

/// Everything the app knows, in one Codable value. Small enough to keep in memory:
/// ten years of daily records plus nightly HR/HRV series is a few tens of megabytes.
struct Database: Codable {
    var schemaVersion: Int = 1
    var personalInfo: PersonalInfo?
    var sleep: [SleepPeriod] = []
    var activity: [ActivityDay] = []
    var readiness: [ReadinessDay] = []
    var spo2: [SpO2Day] = []
    var stress: [StressDay] = []
    var workouts: [Workout] = []
    var cardiovascularAge: [CardiovascularAgeDay] = []
    var resilience: [ResilienceDay] = []
    var vo2Max: [VO2MaxDay] = []
    var sleepTimes: [SleepTimeDay] = []
    var sessions: [MomentSession] = []
    var tags: [DayTag] = []
    var restModePeriods: [RestModePeriod] = []
    var ringInfo: RingInfo?
    var lastSync: Date?
    var earliestSynced: Day?

    var isEmpty: Bool { sleep.isEmpty && activity.isEmpty && readiness.isEmpty }

    var dayRange: (first: Day, last: Day)? {
        var days: [Day] = []
        days.append(contentsOf: sleep.map(\.day))
        days.append(contentsOf: activity.map(\.day))
        days.append(contentsOf: readiness.map(\.day))
        guard let first = days.min(), let last = days.max() else { return nil }
        return (first, last)
    }

    // MARK: - Lookups

    /// The main sleep period recorded for `day` — the longest non-nap, ignoring naps.
    func mainSleep(on day: Day) -> SleepPeriod? {
        let candidates = self.sleep.filter { $0.day == day && $0.isMainSleep }
        return candidates.max(by: { $0.totalSleep < $1.totalSleep })
            ?? self.sleep.filter { $0.day == day }.max(by: { $0.totalSleep < $1.totalSleep })
    }

    func naps(on day: Day) -> [SleepPeriod] {
        let main = mainSleep(on: day)
        return self.sleep.filter { $0.day == day && $0.id != main?.id }
    }

    func activityDay(_ day: Day) -> ActivityDay? { activity.first { $0.day == day } }
    func readinessDay(_ day: Day) -> ReadinessDay? { readiness.first { $0.day == day } }
    func spo2Day(_ day: Day) -> SpO2Day? { spo2.first { $0.day == day } }
    func stressDay(_ day: Day) -> StressDay? { stress.first { $0.day == day } }
    func workoutSessions(_ day: Day) -> [Workout] { workouts.filter { $0.day == day } }
    func cardiovascularAgeDay(_ day: Day) -> CardiovascularAgeDay? { cardiovascularAge.first { $0.day == day } }
    func resilienceDay(_ day: Day) -> ResilienceDay? { resilience.first { $0.day == day } }
    func sleepTimeDay(_ day: Day) -> SleepTimeDay? { sleepTimes.first { $0.day == day } }
    func sessionsOn(_ day: Day) -> [MomentSession] { sessions.filter { $0.day == day } }
    func tagsOn(_ day: Day) -> [DayTag] { tags.filter { $0.day == day } }

    /// VO2 max is measured occasionally, so the useful value is the most recent one.
    var latestVO2Max: VO2MaxDay? { vo2Max.filter { $0.vo2Max != nil }.max { $0.day < $1.day } }
    var latestCardiovascularAge: CardiovascularAgeDay? {
        cardiovascularAge.filter { $0.vascularAge != nil }.max { $0.day < $1.day }
    }

    // MARK: - Merging

    /// Upsert by `id`, newest wins, then keep everything sorted by day.
    mutating func merge(
        sleep newSleep: [SleepPeriod] = [],
        activity newActivity: [ActivityDay] = [],
        readiness newReadiness: [ReadinessDay] = [],
        spo2 newSpO2: [SpO2Day] = [],
        stress newStress: [StressDay] = [],
        workouts newWorkouts: [Workout] = [],
        cardiovascularAge newCVA: [CardiovascularAgeDay] = [],
        resilience newResilience: [ResilienceDay] = [],
        vo2Max newVO2: [VO2MaxDay] = [],
        sleepTimes newSleepTimes: [SleepTimeDay] = [],
        sessions newSessions: [MomentSession] = [],
        tags newTags: [DayTag] = [],
        restModePeriods newRest: [RestModePeriod] = []
    ) {
        self.sleep = Database.upsert(self.sleep, with: newSleep, day: { $0.day })
        self.activity = Database.upsert(self.activity, with: newActivity, day: { $0.day })
        self.readiness = Database.upsert(self.readiness, with: newReadiness, day: { $0.day })
        self.spo2 = Database.upsert(self.spo2, with: newSpO2, day: { $0.day })
        self.stress = Database.upsert(self.stress, with: newStress, day: { $0.day })
        self.workouts = Database.upsert(self.workouts, with: newWorkouts, day: { $0.day })
        self.cardiovascularAge = Database.upsert(self.cardiovascularAge, with: newCVA, day: { $0.day })
        self.resilience = Database.upsert(self.resilience, with: newResilience, day: { $0.day })
        self.vo2Max = Database.upsert(self.vo2Max, with: newVO2, day: { $0.day })
        self.sleepTimes = Database.upsert(self.sleepTimes, with: newSleepTimes, day: { $0.day })
        self.sessions = Database.upsert(self.sessions, with: newSessions, day: { $0.day })
        self.tags = Database.upsert(self.tags, with: newTags, day: { $0.day })
        self.restModePeriods = Database.upsert(self.restModePeriods, with: newRest, day: { $0.start ?? Day.today })
    }

    /// Attach cloud sleep scores (from `daily_sleep`) to the matching nights.
    mutating func applyCloudSleepScores(_ scores: [Day: Int]) {
        guard !scores.isEmpty else { return }
        for index in self.sleep.indices {
            if let score = scores[self.sleep[index].day], self.sleep[index].isMainSleep {
                self.sleep[index].cloudScore = score
            }
        }
    }

    private static func upsert<Element: Identifiable>(
        _ existing: [Element],
        with incoming: [Element],
        day: (Element) -> Day
    ) -> [Element] where Element.ID == String {
        guard !incoming.isEmpty else { return existing }
        var byID: [String: Element] = [:]
        for item in existing { byID[item.id] = item }
        for item in incoming { byID[item.id] = item }
        return byID.values.sorted { day($0) < day($1) }
    }
}
