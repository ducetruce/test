import Foundation

enum OuraError: LocalizedError {
    case missingToken
    case notAuthorised
    case unauthorized
    case rateLimited
    case server(status: Int, body: String)
    case transport(Error)
    case decoding(Error)
    case tokenNotRefreshable
    case stateMismatch
    case authorisationFailed(String)
    case authorisationExpired(String)

    var errorDescription: String? {
        switch self {
        case .missingToken:
            return "No Oura credentials are configured."
        case .notAuthorised:
            return "Not connected to Oura yet. Sign in from Settings."
        case .unauthorized:
            return "Oura rejected the credentials. Sign in again from Settings."
        case .tokenNotRefreshable:
            return "This is a legacy personal access token, which cannot be refreshed. Oura has stopped issuing these — connect with OAuth instead."
        case .stateMismatch:
            return "The sign-in response did not match the request and was discarded."
        case .authorisationFailed(let detail):
            return "Oura declined the authorisation: \(detail.prefix(200))"
        case .authorisationExpired(let detail):
            return "Your Oura authorisation is no longer valid and must be granted again. \(detail.prefix(160))"
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
        // `sleep` is indexed by the day the night *ends*; reach back one day so the first
        // requested morning is never clipped.
        let page: [OuraDTO.Sleep] = try await collect(path: "sleep", from: start.adding(days: -1), to: end)
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
        let page: [OuraDTO.DailyActivity] = try await collect(path: "daily_activity", from: start, to: end)
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

    /// Cheap validation used by onboarding — any 2xx means the credentials work.
    func validateCredentials() async throws {
        _ = try await personalInfo()
    }

    // MARK: - Transport

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

        // One retry with a refreshed token: an access token can expire mid-sync, and a
        // provider that cannot refresh throws, which leaves the original 401 intact.
        if status == 401 || status == 403 {
            guard let refreshed = try? await tokens.refreshedToken() else {
                throw OuraError.unauthorized
            }
            accessToken = refreshed
            (data, status) = try await send(url: url, accessToken: accessToken)
        }

        switch status {
        case 200..<300:
            break
        case 401, 403:
            throw OuraError.unauthorized
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
