import Foundation

enum OuraError: LocalizedError {
    case missingToken
    case notAuthorised
    case unauthorized
    case forbidden
    case notEntitled
    case rateLimited
    case server(status: Int, body: String)
    case transport(Error)
    case decoding(Error)
    case tokenNotRefreshable
    case stateMismatch
    case authorisationFailed(String)
    case authorisationExpired(String)
    case invalidClient(String)
    case secureStorageFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingToken:
            return "No Oura credentials are configured."
        case .notAuthorised:
            return "Not connected to Oura yet. Sign in from Settings."
        case .unauthorized:
            return "Oura rejected the credentials. Sign in again from Settings."
        case .notEntitled:
            return "Refused even though the sign-in is valid, so this is not a login problem. The metric is probably not part of your Oura plan — though if you have not signed in again since new permissions were added, that is worth trying once."
        case .forbidden:
            return "Your Oura sign-in does not cover this data. Either the permission was not granted when you authorised, or it is not part of your Oura plan."
        case .tokenNotRefreshable:
            return "This is a legacy personal access token, which cannot be refreshed. Oura has stopped issuing these — connect with OAuth instead."
        case .stateMismatch:
            return "The sign-in response did not match the request and was discarded."
        case .authorisationFailed(let detail):
            return "Oura declined the authorisation: \(detail.prefix(200))"
        case .invalidClient(let detail):
            return "Oura rejected the client id and secret, both as form fields and as HTTP Basic auth. Check the secret was copied in full — it is shown only once when the application is created, and can be regenerated in the developer portal. \(detail.prefix(160))"
        case .authorisationExpired(let detail):
            return "Your Oura authorisation is no longer valid and must be granted again. \(detail.prefix(160))"
        case .secureStorageFailed(let detail):
            return "Could not save \(detail) securely in the iOS Keychain. Unlock the device and try again."
        case .rateLimited:
            return "Oura rate-limited the request. Wait a minute and sync again."
        case .server(let status, let body):
            return "Oura returned HTTP \(status). \(body.prefix(200))"
        case .transport(let error):
            return "Network error: \(error.localizedDescription)"
        case .decoding(let error):
            return "Could not read Oura's response: \(error.localizedDescription)"
        }
    }
}

/// Thin async wrapper over the Oura v2 REST API, authenticated with a personal access token.
struct OuraClient {
    /// Supplies the bearer token and, for OAuth, can mint a fresh one after a 401.
    var tokens: OuraTokenProviding
    var session: URLSession = .shared

    private static let baseURL = URL(string: "https://api.ouraring.com/v2/usercollection/")!

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    // MARK: - Endpoints

    func personalInfo() async throws -> PersonalInfo {
        let dto: OuraDTO.PersonalInfoDTO = try await get(path: "personal_info", query: [])
        return dto.map()
    }

    func sleepPeriods(from start: Day, to end: Day) async throws -> [SleepPeriod] {
        let window = Self.window(for: .endExclusive, from: start, to: end)
        let page: [OuraDTO.Sleep] = try await collect(path: "sleep", from: window.start, to: window.end)
        return page.compactMap { $0.map() }
    }

    func dailySleep(from start: Day, to end: Day) async throws -> [Day: Int] {
        let page: [OuraDTO.DailySleep] = try await collect(path: "daily_sleep", from: start, to: end)
        var scores: [Day: Int] = [:]
        for item in page {
            if let day = Day(item.day), let score = item.score { scores[day] = score }
        }
        return scores
    }

    func activity(from start: Day, to end: Day) async throws -> [ActivityDay] {
        let window = Self.window(for: .endExclusive, from: start, to: end)
        let page: [OuraDTO.DailyActivity] = try await collect(path: "daily_activity", from: window.start, to: window.end)
        return page.compactMap { $0.map() }
    }

    func readiness(from start: Day, to end: Day) async throws -> [ReadinessDay] {
        let page: [OuraDTO.DailyReadiness] = try await collect(path: "daily_readiness", from: start, to: end)
        return page.compactMap { $0.map() }
    }

    func spo2(from start: Day, to end: Day) async throws -> [SpO2Day] {
        let page: [OuraDTO.DailySpO2] = try await collect(path: "daily_spo2", from: start, to: end)
        return page.compactMap { $0.map() }
    }

    func stress(from start: Day, to end: Day) async throws -> [StressDay] {
        let page: [OuraDTO.DailyStress] = try await collect(path: "daily_stress", from: start, to: end)
        return page.compactMap { $0.map() }
    }

    func workouts(from start: Day, to end: Day) async throws -> [Workout] {
        let page: [OuraDTO.WorkoutDTO] = try await collect(path: "workout", from: start, to: end)
        return page.compactMap { $0.map() }
    }

    func cardiovascularAge(from start: Day, to end: Day) async throws -> [CardiovascularAgeDay] {
        let page: [OuraDTO.DailyCardiovascularAge] = try await collect(path: "daily_cardiovascular_age", from: start, to: end)
        return page.compactMap { $0.map() }
    }

    func resilience(from start: Day, to end: Day) async throws -> [ResilienceDay] {
        let page: [OuraDTO.DailyResilience] = try await collect(path: "daily_resilience", from: start, to: end)
        return page.compactMap { $0.map() }
    }

    func vo2Max(from start: Day, to end: Day) async throws -> [VO2MaxDay] {
        let page: [OuraDTO.VO2Max] = try await collect(path: "vO2_max", from: start, to: end)
        return page.compactMap { $0.map() }
    }

    func sleepTime(from start: Day, to end: Day) async throws -> [SleepTimeDay] {
        let page: [OuraDTO.SleepTime] = try await collect(path: "sleep_time", from: start, to: end)
        return page.compactMap { $0.map() }
    }

    func sessions(from start: Day, to end: Day) async throws -> [MomentSession] {
        let page: [OuraDTO.SessionDTO] = try await collect(path: "session", from: start, to: end)
        return page.compactMap { $0.map() }
    }

    /// `enhanced_tag` supersedes `tag`; fall back so older entries are not lost.
    func tags(from start: Day, to end: Day) async throws -> [DayTag] {
        if let enhanced: [OuraDTO.TagDTO] = try? await collect(path: "enhanced_tag", from: start, to: end),
           !enhanced.isEmpty {
            return enhanced.compactMap { $0.map() }
        }
        let page: [OuraDTO.TagDTO] = try await collect(path: "tag", from: start, to: end)
        return page.compactMap { $0.map() }
    }

    func restModePeriods(from start: Day, to end: Day) async throws -> [RestModePeriod] {
        let page: [OuraDTO.RestModePeriodDTO] = try await collect(path: "rest_mode_period", from: start, to: end)
        return page.compactMap { $0.map() }
    }

    /// Ring hardware and battery are separate endpoints with no date range.
    func ringInfo() async throws -> RingInfo {
        let page: OuraDTO.Page<OuraDTO.RingConfiguration> = try await get(path: "ring_configuration", query: [])
        let battery: OuraDTO.RingBattery? = try? await get(path: "ring_battery_level", query: [])
        guard let latest = page.data.last else {
            return RingInfo(id: nil, design: nil, colour: nil, hardwareType: nil, size: nil,
                            batteryPercentage: battery?.batteryLevel, updatedAt: nil)
        }
        return latest.map(battery: battery?.batteryLevel)
    }

    /// Cheap validation used by onboarding — any 2xx means the credentials work.
    func validateCredentials() async throws {
        _ = try await personalInfo()
    }

    // MARK: - Date window quirks

    /// How an endpoint treats the day named by `end_date`.
    ///
    /// These are not consistent across the API. `sleep` and `daily_activity` do not return
    /// the `end_date` day itself, so asking for a window ending today yields nothing for
    /// today; `daily_readiness` does return it. Observed directly: a retry with the end date
    /// pushed out a day returned the records the original window had omitted.
    ///
    /// `sleep` additionally needs a day of reach-back, because it is indexed by the day a
    /// night *ends*, so the first requested morning would otherwise be clipped.
    enum WindowStyle {
        case endInclusive
        case endExclusive
    }

    static func window(for style: WindowStyle, from start: Day, to end: Day) -> (start: Day, end: Day) {
        switch style {
        case .endInclusive:
            return (start, end)
        case .endExclusive:
            return (start.adding(days: -1), end.adding(days: 1))
        }
    }

    // MARK: - Transport

    /// Records skipped by the most recent `collect`, by endpoint path.
    static let skippedRecords = SkippedCounter()

    final class SkippedCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var counts: [String: Int] = [:]

        func record(_ path: String, _ skipped: Int) {
            lock.lock(); defer { lock.unlock() }
            counts[path, default: 0] += skipped
        }

        func take(_ path: String) -> Int {
            lock.lock(); defer { lock.unlock() }
            return counts.removeValue(forKey: path) ?? 0
        }
    }

    private func collect<Element: Decodable>(path: String, from start: Day, to end: Day) async throws -> [Element] {
        var results: [Element] = []
        var nextToken: String?
        // Oura pages large ranges; 20 pages is far more than a multi-year backfill needs.
        for _ in 0..<20 {
            var query = [
                URLQueryItem(name: "start_date", value: start.description),
                URLQueryItem(name: "end_date", value: end.description)
            ]
            if let nextToken {
                query.append(URLQueryItem(name: "next_token", value: nextToken))
            }
            let page: OuraDTO.Page<Element> = try await get(path: path, query: query)
            results.append(contentsOf: page.data)
            if page.skipped > 0 { Self.skippedRecords.record(path, page.skipped) }
            guard let token = page.nextToken, !token.isEmpty else { break }
            nextToken = token
        }
        return results
    }

    private func get<Response: Decodable>(path: String, query: [URLQueryItem]) async throws -> Response {
        guard var components = URLComponents(url: Self.baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            throw OuraError.server(status: -1, body: "Bad URL for \(path)")
        }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else {
            throw OuraError.server(status: -1, body: "Bad URL for \(path)")
        }

        var accessToken = try await tokens.token()
        var (data, status) = try await send(url: url, accessToken: accessToken)
        var usedFreshToken = false

        // Only 401. A 403 means the token is valid but this endpoint is not covered by the
        // granted scopes, which no refresh can fix — and since Oura's refresh tokens are
        // single use, retrying a 403 spends one every time, on every failing endpoint.
        if status == 401 {
            guard let refreshed = try? await tokens.refreshedToken() else {
                throw OuraError.unauthorized
            }
            accessToken = refreshed
            usedFreshToken = true
            (data, status) = try await send(url: url, accessToken: accessToken)
        }

        switch status {
        case 200..<300:
            break
        case 401:
            // A 401 that survives a refresh is not a stale token — Oura also answers 401
            // for data an account is not entitled to, and telling the user to sign in
            // again cannot fix that.
            throw usedFreshToken ? OuraError.notEntitled : OuraError.unauthorized
        case 403:
            throw OuraError.forbidden
        case 429:
            throw OuraError.rateLimited
        default:
            throw OuraError.server(status: status, body: String(data: data, encoding: .utf8) ?? "")
        }

        do {
            return try Self.decoder.decode(Response.self, from: data)
        } catch {
            throw OuraError.decoding(error)
        }
    }

    private func send(url: URL, accessToken: String) async throws -> (Data, Int) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 60

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw OuraError.server(status: -1, body: "Non-HTTP response")
            }
            return (data, http.statusCode)
        } catch let error as OuraError {
            throw error
        } catch {
            throw OuraError.transport(error)
        }
    }
}
