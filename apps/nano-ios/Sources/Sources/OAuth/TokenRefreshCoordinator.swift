import Foundation

/// Singleton actor that coalesces concurrent token-refresh requests across ALL SourcesManager instances.
///
/// Problems solved:
/// - RootView, SettingsSheet, CloudFolderBrowserView each build a fresh SourcesManager, so the
///   per-instance `refreshTasks` dict on SourcesManager was a no-op serialisation.
/// - A failed refresh Task was cached forever (the slot only cleared on success).
///
/// This actor is the single serialisation point: exactly one refresh POST per account at a time,
/// and the slot clears on both success AND failure (via `defer` inside the Task body).
actor TokenRefreshCoordinator {
    static let shared = TokenRefreshCoordinator()
    private var inFlight: [String: Task<OAuthToken, Error>] = [:]

    /// Returns a valid access token for `account`.
    ///
    /// - If no token is stored → throws immediately (caller should surface `.needsReauth`).
    /// - If token is fresh (not expiring within `skew` seconds) AND `forceRefresh` is false → return it.
    /// - Otherwise coalesce: if a refresh is already in flight for this account, await its result;
    ///   else start one, storing the Task in `inFlight` so concurrent callers join the same request.
    ///   The slot is ALWAYS removed when the Task completes (success or failure).
    func validToken(account: String,
                    store: any TokenStore,
                    client: OAuthClient,
                    forceRefresh: Bool) async throws -> OAuthToken {
        guard let token = try store.load(account: account) else {
            throw OAuthError.noStoredToken(account: account)
        }
        if !forceRefresh && !token.isExpiring(skew: 60) {
            return token
        }
        guard let refreshToken = token.refreshToken else {
            // Token is expiring but we have no refresh token — treat as needs-reauth.
            throw OAuthError.noRefreshToken(account: account)
        }
        // Join an existing in-flight refresh if present.
        if let existing = inFlight[account] {
            return try await existing.value
        }
        // Start a new refresh task. `defer` inside the Task ensures the slot clears on both
        // success and failure, so a failed refresh never permanently wedges this account.
        let task = Task<OAuthToken, Error> { [weak self] in
            defer {
                Task { [weak self] in
                    await self?.clearInFlight(account: account)
                }
            }
            let refreshed = try await client.refresh(refreshToken: refreshToken)
            try store.save(refreshed, account: account)
            return refreshed
        }
        inFlight[account] = task
        return try await task.value
    }

    private func clearInFlight(account: String) {
        inFlight[account] = nil
    }
}

// MARK: - Typed errors

enum OAuthError: Error, LocalizedError {
    case noStoredToken(account: String)
    case noRefreshToken(account: String)

    var errorDescription: String? {
        switch self {
        case .noStoredToken(let a):   return "No stored token for account '\(a)'"
        case .noRefreshToken(let a):  return "No refresh token for account '\(a)'; re-authentication required"
        }
    }
}
