import Foundation

/// Picks whichever credentials the install actually has.
///
/// OAuth wins when present. A legacy personal access token is still honoured for anyone who
/// created one before Oura stopped issuing them in December 2025, but it cannot be refreshed
/// and will stop working when Oura switches those off.
enum AuthResolver {
    /// Shared so the single-use refresh token is only ever spent by one actor.
    static let auth = OuraAuth()

    static func currentProvider() async -> OuraTokenProviding? {
        if await auth.isAuthorised { return auth }
        let legacy = Keychain.get(account: AppModel.tokenAccount) ?? ""
        return legacy.isEmpty ? nil : StaticToken(value: legacy)
    }

    static func hasCredentials() async -> Bool {
        await currentProvider() != nil
    }
}
