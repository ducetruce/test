import Foundation
import UIKit
import AuthenticationServices

/// Runs the OAuth2 authorisation-code flow in a system browser sheet.
///
/// `ASWebAuthenticationSession` is what Apple provides for this: the page runs outside the
/// app, so the app never sees the Oura password, and the redirect back to
/// `openring://oauth-callback` is delivered straight to the completion handler.
@MainActor
final class OuraSignIn: NSObject {

    private var session: ASWebAuthenticationSession?

    /// Opens the browser sheet, waits for the redirect, and exchanges the code for tokens.
    func run(clientID: String, clientSecret: String, auth: OuraAuth) async throws -> OuraCredentials {
        let trimmedID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSecret = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty, !trimmedSecret.isEmpty else {
            throw OuraError.authorisationFailed("client id and secret are both required")
        }
        guard let url = OuraAuth.authorizationURL(clientID: trimmedID, state: OuraAuth.makeState()) else {
            throw OuraError.authorisationFailed("could not build the authorisation URL")
        }
        // Regenerating the state here would defeat the check, so reuse the one in the URL.
        let state = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "state" }?.value ?? ""

        let callback = try await present(url: url)
        let grant = try OuraAuth.authorizationGrant(from: callback, expectedState: state)
        return try await auth.exchange(
            code: grant.code,
            clientID: trimmedID,
            clientSecret: trimmedSecret,
            grantedScopes: grant.scopes
        )
    }

    private func present(url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let scheme = URL(string: OuraAuth.redirectURI)?.scheme ?? "openring"
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme) { callback, error in
                if let error {
                    let cancelled = (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin
                    continuation.resume(
                        throwing: cancelled
                            ? OuraError.authorisationFailed("sign-in was cancelled")
                            : OuraError.transport(error)
                    )
                    return
                }
                guard let callback else {
                    continuation.resume(throwing: OuraError.authorisationFailed("no redirect received"))
                    return
                }
                continuation.resume(returning: callback)
            }
            session.presentationContextProvider = self
            // A private session would force a fresh Oura login every time; sharing the
            // browser's cookies means an already-signed-in user just taps Allow.
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            if !session.start() {
                continuation.resume(throwing: OuraError.authorisationFailed("could not open the sign-in page"))
            }
        }
    }
}

extension OuraSignIn: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // The key window of the active foreground scene, falling back to a bare anchor so
        // this can never crash on a scene that has gone away mid-flow.
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        return scene?.keyWindow ?? ASPresentationAnchor()
    }
}
