import Foundation
import SwiftUI

/// Single source of truth for the UI: the local database, the derived scores, and the
/// state of the last sync. Everything renders from the local copy, so the app is fully
/// usable with no network.
@MainActor
final class AppModel: ObservableObject {
    nonisolated static let tokenAccount = "oura-personal-access-token"
    nonisolated static let ringKeyAccount = "oura-ring-auth-key"
    nonisolated static let pendingRingKeyAccount = "oura-ring-auth-key-pending"
    nonisolated static let clientIDAccount = "oura-client-id"
    nonisolated static let clientSecretAccount = "oura-client-secret"

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

    /// Mirrors the stored credentials so SwiftUI has something observable to react to.
    /// Seeded from the legacy token synchronously; OAuth state arrives from `refreshConnection()`.
    @Published private(set) var isConnected: Bool = !(Keychain.get(account: AppModel.tokenAccount) ?? "").isEmpty

    nonisolated private static let onboardingKey = "hasCompletedOnboarding"

    private let signIn = OuraSignIn()
    private let store = LocalStore()
    private lazy var syncEngine = SyncEngine(store: store)
    private let engine = ScoreEngine()

    var lastSync: Date? { database.lastSync }

    // MARK: - Lifecycle

    /// Set when the app asks for a permission the stored authorisation never granted.
    @Published private(set) var needsReauthorisation = false

    /// The scopes Oura reported granting, and the ones the app asks for that are missing.
    @Published private(set) var grantedScopes: [String] = []
    @Published private(set) var missingScopes: [String] = []

    /// OAuth credentials live behind an actor, so connection state has to be awaited.
    func refreshConnection() async {
        isConnected = await AuthResolver.hasCredentials()
        needsReauthorisation = await AuthResolver.auth.needsReauthorisationForNewScopes
        grantedScopes = await AuthResolver.auth.grantedScopes
        missingScopes = grantedScopes.isEmpty ? [] : OuraAuth.scopes.filter { !grantedScopes.contains($0) }
    }

    func loadFromDisk() async {
        await store.invalidateCache()
        let loaded = await store.load()
        database = loaded
        recomputeScores()
        isLoaded = true
    }

    func syncIfStale(maximumAge: TimeInterval = 30 * 60) async {
        guard isConnected else { return }
        if let last = database.lastSync, Date().timeIntervalSince(last) < maximumAge { return }
        await sync()
    }

    func sync(fullHistory: Bool = false) async {
        guard let tokens = await AuthResolver.currentProvider() else {
            errorMessage = OuraError.notAuthorised.localizedDescription
            return
        }
        guard !isSyncing else { return }
        isSyncing = true
        errorMessage = nil
        defer { isSyncing = false }

        do {
            let result = try await syncEngine.sync(using: tokens, fullHistory: fullHistory)
            database = result.database
            warnings = result.warnings
            recomputeScores()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: - Credentials

    /// The application keys, kept so a failed attempt does not cost the user retyping a
    /// long secret. These are the user's own credentials, not a shared app secret.
    var savedClientID: String { Keychain.get(account: Self.clientIDAccount) ?? "" }
    var savedClientSecret: String { Keychain.get(account: Self.clientSecretAccount) ?? "" }

    /// Runs the OAuth2 flow end to end. Returns an error message, or nil on success.
    func connect(clientID: String, clientSecret: String) async -> String? {
        let trimmedID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSecret = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        // `??` short-circuits, so the secret is not written when the id already failed.
        if let failure = Keychain.set(trimmedID, account: Self.clientIDAccount).failure
            ?? Keychain.set(trimmedSecret, account: Self.clientSecretAccount).failure {
            return OuraError.secureStorageFailed("the Oura application credentials", failure).localizedDescription
        }
        do {
            _ = try await signIn.run(clientID: clientID, clientSecret: clientSecret, auth: AuthResolver.auth)
            isConnected = true
            hasCompletedOnboarding = true
            await sync(fullHistory: true)
            return nil
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Legacy path: a personal access token created before Oura stopped issuing them.
    func saveLegacyToken(_ token: String) async -> String? {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Paste a token first." }
        do {
            try await OuraClient(tokens: StaticToken(value: trimmed)).validateCredentials()
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        if let failure = Keychain.set(trimmed, account: Self.tokenAccount).failure {
            return OuraError.secureStorageFailed("the legacy Oura token", failure).localizedDescription
        }
        isConnected = true
        hasCompletedOnboarding = true
        return nil
    }

    func signOut() async {
        Keychain.delete(account: Self.tokenAccount)
        Keychain.delete(account: Self.clientIDAccount)
        Keychain.delete(account: Self.clientSecretAccount)
        await AuthResolver.auth.signOut()
        isConnected = false
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

    /// A staged key wins after an interrupted claim: the ring may already have accepted it,
    /// so retaining and presenting that key is the only recoverable choice.
    var ringKey: String {
        let pending = Keychain.get(account: Self.pendingRingKeyAccount) ?? ""
        return pending.isEmpty ? (Keychain.get(account: Self.ringKeyAccount) ?? "") : pending
    }

    @discardableResult
    func saveRingKey(_ key: String) -> Result<Void, Keychain.WriteFailure> {
        let outcome = Keychain.set(key.trimmingCharacters(in: .whitespacesAndNewlines), account: Self.ringKeyAccount)
        guard outcome.succeeded else { return outcome }
        Keychain.delete(account: Self.pendingRingKeyAccount)
        objectWillChange.send()
        return .success(())
    }

    func stageRingKey(_ key: String) -> Result<Void, Keychain.WriteFailure> {
        Keychain.set(key.trimmingCharacters(in: .whitespacesAndNewlines), account: Self.pendingRingKeyAccount)
    }

    func commitStagedRingKey() -> Bool {
        guard let pending = Keychain.get(account: Self.pendingRingKeyAccount), !pending.isEmpty,
              Keychain.set(pending, account: Self.ringKeyAccount).succeeded else { return false }
        Keychain.delete(account: Self.pendingRingKeyAccount)
        objectWillChange.send()
        return true
    }

    func discardStagedRingKey() {
        Keychain.delete(account: Self.pendingRingKeyAccount)
        objectWillChange.send()
    }

    func eraseAllData() async {
        await store.reset()
        database = Database()
        scores = [:]
    }

    /// Paired scores plus the inputs behind them, for retuning the curves.
    func exportCalibration() async -> URL? {
        let csv = CalibrationExport.csv(database: database, scores: scores)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("openring-calibration-\(Day.today).csv")
        try? Data(csv.utf8).write(to: url, options: .atomic)
        return url
    }

    var completeDayCount: Int { CalibrationExport.completeDayCount(scores: scores) }

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
