import Foundation
import Security

/// OAuth2 credentials for the Oura API.
///
/// Personal access tokens were deprecated in December 2025 and can no longer be created, so
/// OAuth2 is the only route for a new install. The client id and secret belong to an
/// application you register yourself; they live in the Keychain and never touch the repo.
struct OuraCredentials: Codable, Equatable {
    var clientID: String
    var clientSecret: String
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    /// What was actually granted when this authorisation was made. Compared against the
    /// current request list so a scope added later can prompt for re-authorisation instead
    /// of silently returning 403 forever.
    var grantedScopes: [String] = []

    /// Treated as expired a minute early so a sync never starts with a token about to die.
    var isExpired: Bool { Date() >= expiresAt.addingTimeInterval(-60) }
}

/// Anything that can hand the client a bearer token, and possibly get a fresh one.
protocol OuraTokenProviding {
    func token() async throws -> String
    /// Force a refresh, for use after a 401. Throws if this provider cannot refresh.
    func refreshedToken() async throws -> String
}

/// A legacy personal access token. Still works for anyone who created one before Oura
/// stopped issuing them, but it cannot be refreshed and will stop working when Oura
/// switches them off.
struct StaticToken: OuraTokenProviding {
    var value: String

    func token() async throws -> String {
        guard !value.isEmpty else { throw OuraError.missingToken }
        return value
    }

    func refreshedToken() async throws -> String {
        throw OuraError.tokenNotRefreshable
    }
}

/// Owns the OAuth2 credentials and the refresh dance.
///
/// An actor because Oura's refresh tokens are **single use**: every refresh returns a new
/// one and invalidates the old. Two concurrent refreshes would spend the same token twice
/// and lock the account out until the user re-authorises, so refreshes must serialise.
actor OuraAuth: OuraTokenProviding {
    static let authorizeURL = URL(string: "https://cloud.ouraring.com/oauth/authorize")!
    static let tokenURL = URL(string: "https://api.ouraring.com/oauth/token")!
    static let revokeURL = URL(string: "https://api.ouraring.com/oauth/revoke")!

    /// The redirect the app registers in its Info.plist. Whatever you enter here must match
    /// the redirect URI on the Oura application exactly.
    static let redirectURI = "openring://oauth-callback"

    /// The complete scope list documented by Oura. Keep these wire values exact: unknown
    /// values can make the authorization request fail, and the SpO2 scope is `spo2` even
    /// though its API endpoint is named `daily_spo2`.
    static let scopes = ["email", "personal", "daily", "heartrate", "workout", "tag", "session", "spo2"]

    private static let keychainAccount = "oura-oauth-credentials"

    private var credentials: OuraCredentials?
    private var lastRefresh: Date?
    /// Actor isolation alone does not coalesce refreshes: actors are re-entrant while a
    /// network request is suspended. Every caller must await the same in-flight task or two
    /// simultaneous 401s can spend the same single-use refresh token.
    private var refreshTask: Task<OuraCredentials, Error>?
    private let session: URLSession
    private let persistsCredentials: Bool

    init(session: URLSession = .shared) {
        self.session = session
        self.credentials = Self.loadFromKeychain()
        self.persistsCredentials = true
    }

    /// Dependency-injected state for deterministic transport and concurrency tests.
    init(session: URLSession, credentials: OuraCredentials?) {
        self.session = session
        self.credentials = credentials
        self.persistsCredentials = false
    }

    var isAuthorised: Bool { credentials != nil }

    var current: OuraCredentials? { credentials }

    /// True when the app now asks for scopes this authorisation may never have granted.
    ///
    /// An empty list means the credentials predate scope tracking, so what they cover is
    /// unknown. Prompt once rather than silently treating an unknown historical grant as
    /// complete and returning unexplained permission failures later.
    var needsReauthorisationForNewScopes: Bool {
        guard let credentials else { return false }
        guard !credentials.grantedScopes.isEmpty else { return true }
        return !Set(Self.scopes).isSubset(of: Set(credentials.grantedScopes))
    }

    // MARK: - Authorisation URL

    /// `state` is returned unchanged by Oura and must be checked, or a malicious redirect
    /// could hand us someone else's authorisation code.
    nonisolated static func authorizationURL(clientID: String, state: String) -> URL? {
        var components = URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: state)
        ]
        return components?.url
    }

    nonisolated static func makeState() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            // The state only needs to be unguessable within this launch; a UUID is adequate.
            return UUID().uuidString
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    struct AuthorizationGrant: Equatable {
        var code: String
        /// Oura can return fewer scopes than were requested if the user disables one on the
        /// consent screen. An empty array means the response did not state the grant.
        var scopes: [String]
    }

    /// Pulls the code and actual grant out of the redirect, rejecting a mismatched or missing
    /// `state`. The callback's scope list is authoritative; it may be a subset of the request.
    nonisolated static func authorizationGrant(from callback: URL, expectedState: String) throws -> AuthorizationGrant {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }

        if let error = value("error") {
            throw OuraError.authorisationFailed(error)
        }
        guard let state = value("state"), state == expectedState else {
            throw OuraError.stateMismatch
        }
        guard let code = value("code"), !code.isEmpty else {
            throw OuraError.authorisationFailed("no authorisation code in the redirect")
        }
        let grantedScopes = value("scope")?
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init) ?? []
        return AuthorizationGrant(code: code, scopes: grantedScopes)
    }

    // MARK: - Token exchange

    func exchange(
        code: String,
        clientID: String,
        clientSecret: String,
        grantedScopes: [String]
    ) async throws -> OuraCredentials {
        let credentials = try await requestToken(
            form: [
                "grant_type": "authorization_code",
                "code": code,
                "redirect_uri": Self.redirectURI,
                "client_id": clientID,
                "client_secret": clientSecret
            ],
            clientID: clientID,
            clientSecret: clientSecret,
            previousRefreshToken: nil,
            grantedScopes: grantedScopes
        )
        try store(credentials)
        return credentials
    }

    // MARK: - OuraTokenProviding

    func token() async throws -> String {
        guard let credentials else { throw OuraError.notAuthorised }
        if credentials.isExpired {
            return try await refresh().accessToken
        }
        return credentials.accessToken
    }

    /// A sync touches a dozen endpoints. If several answer 401 — which Oura does for
    /// metrics an account is not entitled to, not only for stale tokens — each one would
    /// otherwise trigger its own refresh, and these refresh tokens are single use. So a
    /// refresh that just happened is reused rather than repeated.
    func refreshedToken() async throws -> String {
        if let lastRefresh, Date().timeIntervalSince(lastRefresh) < 60,
           let credentials, !credentials.isExpired {
            return credentials.accessToken
        }
        return try await refresh().accessToken
    }

    @discardableResult
    private func refresh() async throws -> OuraCredentials {
        if let refreshTask {
            return try await refreshTask.value
        }
        guard let existing = credentials else { throw OuraError.notAuthorised }
        let task = Task {
            try await self.requestToken(
                form: [
                    "grant_type": "refresh_token",
                    "refresh_token": existing.refreshToken,
                    "client_id": existing.clientID,
                    "client_secret": existing.clientSecret
                ],
                clientID: existing.clientID,
                clientSecret: existing.clientSecret,
                previousRefreshToken: nil,
                grantedScopes: existing.grantedScopes
            )
        }
        refreshTask = task
        do {
            let refreshed = try await task.value
            refreshTask = nil
            do {
                try store(refreshed)
            } catch {
                // The old persisted refresh token has already been spent. Retain the new
                // credentials for this process so concurrent callers do not spend it again;
                // the surfaced error tells the user the durable copy needs attention.
                credentials = refreshed
                lastRefresh = Date()
                throw error
            }
            lastRefresh = Date()
            return refreshed
        } catch {
            refreshTask = nil
            throw error
        }
    }

    // MARK: - Storage

    func signOut() {
        credentials = nil
        Keychain.delete(account: Self.keychainAccount)
    }

    private func store(_ credentials: OuraCredentials) throws {
        guard persistsCredentials else {
            self.credentials = credentials
            return
        }
        guard let data = try? JSONEncoder().encode(credentials),
              let json = String(data: data, encoding: .utf8),
              Keychain.set(json, account: Self.keychainAccount) else {
            throw OuraError.secureStorageFailed("the Oura authorization")
        }
        self.credentials = credentials
    }

    private static func loadFromKeychain() -> OuraCredentials? {
        guard let json = Keychain.get(account: keychainAccount),
              let data = json.data(using: .utf8) else { return nil }
        return decodeStoredCredentials(data)
    }

    /// Credentials written before `grantedScopes` existed need an explicit migration:
    /// Codable does not apply a stored property's default when a JSON key is absent.
    nonisolated static func decodeStoredCredentials(_ data: Data) -> OuraCredentials? {
        let decoder = JSONDecoder()
        if let current = try? decoder.decode(OuraCredentials.self, from: data) { return current }

        struct LegacyCredentials: Decodable {
            var clientID: String
            var clientSecret: String
            var accessToken: String
            var refreshToken: String
            var expiresAt: Date
        }
        guard let legacy = try? decoder.decode(LegacyCredentials.self, from: data) else { return nil }
        return OuraCredentials(
            clientID: legacy.clientID,
            clientSecret: legacy.clientSecret,
            accessToken: legacy.accessToken,
            refreshToken: legacy.refreshToken,
            expiresAt: legacy.expiresAt,
            grantedScopes: []
        )
    }

    // MARK: - Transport

    private struct TokenResponse: Decodable {
        var accessToken: String
        var refreshToken: String?
        var expiresIn: Double?
        var tokenType: String?
    }

    /// OAuth2 lets a server take client credentials either as form fields or as HTTP Basic
    /// auth, and providers differ on which they accept. Rather than bet on one, try the form
    /// first and fall back to Basic when the server answers `invalid_client`.
    private func requestToken(
        form: [String: String],
        clientID: String,
        clientSecret: String,
        previousRefreshToken: String?,
        grantedScopes: [String]
    ) async throws -> OuraCredentials {
        do {
            return try await attemptToken(
                form: form, clientID: clientID, clientSecret: clientSecret,
                previousRefreshToken: previousRefreshToken, grantedScopes: grantedScopes,
                useBasicAuth: false
            )
        } catch OuraError.invalidClient {
            return try await attemptToken(
                form: form, clientID: clientID, clientSecret: clientSecret,
                previousRefreshToken: previousRefreshToken, grantedScopes: grantedScopes,
                useBasicAuth: true
            )
        }
    }

    private func attemptToken(
        form: [String: String],
        clientID: String,
        clientSecret: String,
        previousRefreshToken: String?,
        grantedScopes: [String],
        useBasicAuth: Bool
    ) async throws -> OuraCredentials {
        var request = URLRequest(url: Self.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        var fields = form
        if useBasicAuth {
            // With Basic the credentials move out of the body entirely, which is what a
            // server that insists on Basic expects to see.
            fields.removeValue(forKey: "client_id")
            fields.removeValue(forKey: "client_secret")
            let pair = Data("\(clientID):\(clientSecret)".utf8).base64EncodedString()
            request.setValue("Basic \(pair)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = Self.formEncode(fields).data(using: .utf8)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw OuraError.transport(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw OuraError.server(status: -1, body: "Non-HTTP response from the token endpoint")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            // Distinguished so the caller can retry with the other client-auth style; only
            // this exact error means "I do not accept these credentials this way".
            if body.contains("invalid_client") {
                throw OuraError.invalidClient(body)
            }
            // Any other 4xx on a refresh means the grant itself is gone and the user has to
            // authorise again, which is more useful to say than a bare status code.
            if (400..<500).contains(http.statusCode) {
                throw OuraError.authorisationExpired(body)
            }
            throw OuraError.server(status: http.statusCode, body: body)
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let token = try? decoder.decode(TokenResponse.self, from: data) else {
            throw OuraError.decoding(OuraError.server(status: http.statusCode, body: "unreadable token response"))
        }
        guard let refreshToken = token.refreshToken ?? previousRefreshToken else {
            throw OuraError.authorisationFailed("no refresh token in the response")
        }

        return OuraCredentials(
            clientID: clientID,
            clientSecret: clientSecret,
            accessToken: token.accessToken,
            refreshToken: refreshToken,
            expiresAt: Date().addingTimeInterval(token.expiresIn ?? 3600),
            grantedScopes: grantedScopes
        )
    }

    private static func formEncode(_ fields: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields
            .map { key, value in
                let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
                let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
                return "\(encodedKey)=\(encodedValue)"
            }
            .joined(separator: "&")
    }
}
