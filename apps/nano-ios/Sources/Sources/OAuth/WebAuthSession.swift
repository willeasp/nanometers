import Foundation
import AuthenticationServices

/// Thin async wrapper over `ASWebAuthenticationSession` (handoff §08.4).
/// Opens the authorize URL in an ephemeral browser session, waits for the callback,
/// verifies the `state` parameter, and returns the authorization code.
/// This is the interactive piece — it cannot be unit-tested headlessly.
@MainActor
final class WebAuthSession: NSObject, ASWebAuthenticationPresentationContextProviding {

    enum Error: Swift.Error {
        case cancelled
        case missingCode
        case stateMismatch(got: String?, expected: String)
        case underlying(Swift.Error)
    }

    /// Opens `url` in an ephemeral browser, awaits the callback on `callbackScheme`, verifies
    /// the `state` query parameter matches `expectedState`, and returns the auth `code`.
    func authorize(url: URL, callbackScheme: String, expectedState: String) async throws -> String {
        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { callbackURL, error in
                if let error {
                    if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin {
                        continuation.resume(throwing: Error.cancelled)
                    } else {
                        continuation.resume(throwing: Error.underlying(error))
                    }
                    return
                }
                guard let callbackURL else {
                    continuation.resume(throwing: Error.missingCode)
                    return
                }
                let items = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems
                let receivedState = items?.first { $0.name == "state" }?.value
                guard receivedState == expectedState else {
                    continuation.resume(throwing: Error.stateMismatch(got: receivedState, expected: expectedState))
                    return
                }
                guard let code = items?.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
                    continuation.resume(throwing: Error.missingCode)
                    return
                }
                continuation.resume(returning: code)
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = true
            session.start()
        }
    }

    // MARK: - ASWebAuthenticationPresentationContextProviding

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // Return the key window; falls back to a new UIWindow if none exists (unlikely in real use).
        (UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }) ?? UIWindow()
    }
}
