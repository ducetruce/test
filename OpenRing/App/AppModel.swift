import Foundation
import SwiftUI

/// Single source of truth for the UI: the local database, the derived scores, and the
/// state of the last sync. Everything renders from the local copy, so the app is fully
/// usable with no network.
@MainActor
final class AppModel: ObservableObject {
    nonisolated static let tokenAccount = "oura-personal-access-token"
    nonisolated static let ringKeyAccount = "oura-ring-auth-key"

    @Published private(set) var database = Database()
    @Published private(set) var scores: [Day: DayScores] = [:]
    @Published private(set) var isSyncing = false
    @Published private(set) var isLoaded = false
    @Published var errorMessage: String?
    @Published var warnings: [String] = []
    @Published var selectedDay: Day = .today
    @Published var importReport: ExportImporter.Report?

    /// Backed by UserDefaults by hand rather than `@AppStorage`: inside an ObservableObject
    /// `@AppStorage` does not publish, so the root view would not swap away from onboarding.
    ///
    /// Seeded by a default-value expression rather than an initializer body: assigning to a
    /// main-actor-isolated property from a nonisolated init is an error, while evaluating a
    /// stored property's default is not.
    @Published var hasCompletedOnboarding: Bool = UserDefaults.standard.bool(forKey: AppModel.onboardingKey) {
        didSet { UserDefaults.standard.set(hasCompletedOnboarding, forKey: AppModel.onboardingKey) }
    }

    /// Mirrors the Keychain so SwiftUI has something observable to react to.
    @Published private(set) var hasToken: Bool = !(Keychain.get(account: AppModel.tokenAccount) ?? "").isEmpty

    nonisolated private static let onboardingKey = "hasCompletedOnboarding"

    private let store = LocalStore()
    private lazy var syncEngine = SyncEngine(store: store)
    private let engine = ScoreEngine()

    var token: String? {
        Keychain.get(account: Self.tokenAccount)
    }

    var lastSync: Date? { database.lastSync }

    // MARK: - Lifecycle

    func loadFromDisk() async {
        await store.invalidateCache()
        let loaded = await store.load()
        database = loaded
        recomputeScores()
        isLoaded = true
    }

    func syncIfStale(maximumAge: TimeInterval = 30 * 60) async {
        guard hasToken else { return }
        if let last = database.lastSync, Date().timeIntervalSince(last) < maximumAge { return }
        await sync()
    }

    func sync(fullHistory: Bool = false) async {
        guard let token, !token.isEmpty else {
            errorMessage = OuraError.missingToken.localizedDescription
            return
        }
        guard !isSyncing else { return }
        isSyncing = true
        errorMessage = nil
        defer { isSyncing = false }

        do {
            let result = try await syncEngine.sync(token: token, fullHistory: fullHistory)
            database = result.database
            warnings = result.warnings
            recomputeScores()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: - Token

    func saveToken(_ token: String) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        Keychain.set(trimmed, account: Self.tokenAccount)
        hasToken = !trimmed.isEmpty
    }

    func validate(token: String) async -> String? {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Paste a personal access token first." }
        do {
            try await OuraClient(token: trimmed).validateToken()
            return nil
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func signOut() {
        Keychain.delete(account: Self.tokenAccount)
        hasToken = false
        hasCompletedOnboarding = false
    }

    // MARK: - Data export import

    /// Imports an official Oura data-export file (ZIP, CSV or JSON). Needs no token and no
    /// membership; exported rows only fill days the API has not already provided.
    func importExport(at url: URL) async {
        let current = database
        do {
            let outcome = try await Task.detached(priority: .userInitiated) { () -> (Database, ExportImporter.Report) in
                var working = current
                let report = try ExportImporter.importFile(at: url, into: &working)
                return (working, report)
            }.value

            try await store.save(outcome.0)
            database = outcome.0
            importReport = outcome.1
            recomputeScores()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: - Ring auth key

    var ringKey: String { Keychain.get(account: Self.ringKeyAccount) ?? "" }

    func saveRingKey(_ key: String) {
        Keychain.set(key.trimmingCharacters(in: .whitespacesAndNewlines), account: Self.ringKeyAccount)
        objectWillChange.send()
    }

    func eraseAllData() async {
        await store.reset()
        database = Database()
        scores = [:]
    }

    func exportData() async -> URL? {
        guard let data = try? await store.exportJSON() else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("openring-export-\(Day.today).json")
        try? data.write(to: url, options: .atomic)
        return url
    }

    // MARK: - Derived data

    private func recomputeScores() {
        scores = engine.allScores(in: database)
    }

    func dayScores(for day: Day) -> DayScores {
        scores[day] ?? DayScores(day: day)
    }

    /// Most recent day that has any data at all — what "Today" falls back to before the
    /// ring has synced this morning.
    var latestDayWithData: Day {
        scores.keys.max() ?? Day.today
    }

    func recentDays(_ count: Int, endingAt day: Day? = nil) -> [Day] {
        let end = day ?? latestDayWithData
        return Day.range(from: end.adding(days: -(count - 1)), through: end)
    }

    func trend(_ metric: TrendMetric, days: Int) -> [DayPoint] {
        recentDays(days).compactMap { day in
            guard let value = metric.value(day: day, database: database, scores: scores[day]) else { return nil }
            return DayPoint(day: day, value: value)
        }
    }
}

/// One day's value of a trend metric.
struct DayPoint: Identifiable, Hashable {
    var day: Day
    var value: Double

    var id: String { day.description }
    var date: Date { day.startOfDay() }
}

/// Everything the Trends tab can plot, defined in one place.
enum TrendMetric: String, CaseIterable, Identifiable {
    case sleepScore, readinessScore, activityScore
    case sleepDuration, restingHeartRate, hrv, temperature, steps, activeCalories

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sleepScore: return "Sleep score"
        case .readinessScore: return "Readiness score"
        case .activityScore: return "Activity score"
        case .sleepDuration: return "Time asleep"
        case .restingHeartRate: return "Resting heart rate"
        case .hrv: return "HRV"
        case .temperature: return "Temperature deviation"
        case .steps: return "Steps"
        case .activeCalories: return "Active calories"
        }
    }

    var unit: String {
        switch self {
        case .sleepScore, .readinessScore, .activityScore: return ""
        case .sleepDuration: return "h"
        case .restingHeartRate: return "bpm"
        case .hrv: return "ms"
        case .temperature: return "°C"
        case .steps: return ""
        case .activeCalories: return "kcal"
        }
    }

    var tint: Color {
        switch self {
        case .sleepScore, .sleepDuration: return Theme.sleep
        case .readinessScore, .restingHeartRate, .hrv, .temperature: return Theme.readiness
        case .activityScore, .steps, .activeCalories: return Theme.activity
        }
    }

    func value(day: Day, database: Database, scores: DayScores?) -> Double? {
        switch self {
        case .sleepScore: return scores?.sleep.map { Double($0.value) }
        case .readinessScore: return scores?.readiness.map { Double($0.value) }
        case .activityScore: return scores?.activity.map { Double($0.value) }
        case .sleepDuration: return database.mainSleep(on: day).map { $0.totalSleep / 3600 }
        case .restingHeartRate: return database.mainSleep(on: day)?.lowestHeartRate
        case .hrv: return database.mainSleep(on: day)?.averageHRV
        case .temperature: return database.readinessDay(day)?.temperatureDeviation
        case .steps: return database.activityDay(day).map { Double($0.steps) }
        case .activeCalories: return database.activityDay(day)?.activeCalories
        }
    }
}
