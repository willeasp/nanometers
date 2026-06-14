import Foundation

/// Authorize URL + token exchange/refresh (interactive session is separate, Task 8).
struct OAuthClient {
    let config: OAuthConfig; let http: HTTPClient
    func authorizeURL(challenge: String, state: String, redirectURI: String) -> URL {
        var c = URLComponents(url: config.authEndpoint, resolvingAgainstBaseURL: false)!
        c.queryItems = [.init(name: "client_id", value: config.clientID), .init(name: "redirect_uri", value: redirectURI),
                        .init(name: "response_type", value: "code"), .init(name: "scope", value: config.scopes.joined(separator: " ")),
                        .init(name: "code_challenge", value: challenge), .init(name: "code_challenge_method", value: "S256"),
                        .init(name: "state", value: state)]
        // Provider-specific params (Google: access_type=offline + prompt=consent; Microsoft:
        // prompt=select_account). Sorted by key so the URL is deterministic for tests.
        c.queryItems! += config.extraAuthParams.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return c.url!
    }
    func exchange(code: String, verifier: String, redirectURI: String) async throws -> OAuthToken {
        try await token(form: ["grant_type": "authorization_code", "code": code, "code_verifier": verifier,
                               "redirect_uri": redirectURI, "client_id": config.clientID], existingRefresh: nil)
    }
    func refresh(refreshToken: String) async throws -> OAuthToken {
        try await token(form: ["grant_type": "refresh_token", "refresh_token": refreshToken, "client_id": config.clientID],
                        existingRefresh: refreshToken)
    }
    private func token(form: [String: String], existingRefresh: String?) async throws -> OAuthToken {
        var req = URLRequest(url: config.tokenEndpoint); req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let formSafe = CharacterSet.alphanumerics.union(.init(charactersIn: "-._~"))
        req.httpBody = Data(form.map { "\($0)=\($1.addingPercentEncoding(withAllowedCharacters: formSafe) ?? $1)" }.joined(separator: "&").utf8)
        let resp = try await http.send(req)
        guard resp.status == 200 else { throw NSError(domain: "OAuth", code: resp.status) }
        struct R: Decodable { var access_token: String; var refresh_token: String?; var expires_in: Double? }
        let r = try JSONDecoder().decode(R.self, from: resp.data)
        return OAuthToken(accessToken: r.access_token, refreshToken: r.refresh_token ?? existingRefresh,
                          expiry: Date(timeIntervalSinceNow: r.expires_in ?? 3600))
    }
}
