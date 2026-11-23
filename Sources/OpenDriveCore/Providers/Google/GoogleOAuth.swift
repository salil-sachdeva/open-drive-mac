import CryptoKit
import Foundation
import Security

/// Google OAuth 2.0 authorization-code flow with PKCE for installed apps.
public enum GoogleOAuth {
    public static let authorizationEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    public static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
    public static let defaultScopes = [
        "openid",
        "email",
        "https://www.googleapis.com/auth/drive"
    ]

    // MARK: - PKCE

    /// A freshly generated PKCE verifier/challenge pair plus a CSRF `state` token.
    public struct PKCEChallenge: Sendable {
        public let verifier: String
        public let challenge: String
        public let state: String

        public init() {
            let verifierKey = SymmetricKey(size: .bits256)
            self.verifier = verifierKey.withUnsafeBytes { Base64URL.encode(Data($0)) }
            let digest = SHA256.hash(data: Data(verifier.utf8))
            self.challenge = Base64URL.encode(Data(digest))
            let stateKey = SymmetricKey(size: .bits256)
            self.state = stateKey.withUnsafeBytes { Base64URL.encode(Data($0)) }
        }
    }

    // MARK: - Authorization

    /// Builds the browser consent URL requesting offline access.
    public static func buildAuthorizationURL(
        clientId: String,
        redirectURI: String,
        pkce: PKCEChallenge,
        scopes: [String] = defaultScopes
    ) -> URL {
        var components = URLComponents(url: authorizationEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "state", value: pkce.state)
        ]
        return components.url!
    }

    /// Parses the OAuth authorization code from a loopback HTTP request path or full redirect URL
    /// and verifies the CSRF `state` token.
    public static func parseAuthorizationCallback(
        requestPathOrURL: String,
        expectedState: String
    ) throws -> String {
        let normalized: String
        if requestPathOrURL.hasPrefix("http://") || requestPathOrURL.hasPrefix("https://") {
            normalized = requestPathOrURL
        } else if requestPathOrURL.hasPrefix("/") {
            normalized = "http://127.0.0.1\(requestPathOrURL)"
        } else {
            normalized = "http://127.0.0.1/\(requestPathOrURL)"
        }

        guard let components = URLComponents(string: normalized) else {
            throw GoogleDriveError.oauthFailed("Malformed OAuth callback URL")
        }
        let items = components.queryItems ?? []
        if let error = items.first(where: { $0.name == "error" })?.value {
            let desc = items.first(where: { $0.name == "error_description" })?.value ?? error
            throw GoogleDriveError.oauthFailed("User or server denied OAuth: \(desc)")
        }
        guard let returnedState = items.first(where: { $0.name == "state" })?.value,
              LocalWebDAVServer.constantTimeEquals(returnedState, expectedState) else {
            throw GoogleDriveError.oauthFailed("OAuth CSRF state mismatch")
        }
        guard let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            throw GoogleDriveError.oauthFailed("Missing authorization code in callback")
        }
        return code
    }

    // MARK: - Token Endpoint

    /// Exchanges an authorization code for an access/refresh token pair.
    public static func exchangeCodeForTokens(
        code: String,
        clientId: String,
        clientSecret: String? = nil,
        redirectURI: String,
        codeVerifier: String,
        session: URLSession = .shared
    ) async throws -> OAuthTokenSet {
        let params: [(String, String)] = [
            ("client_id", clientId),
            ("code", code),
            ("code_verifier", codeVerifier),
            ("grant_type", "authorization_code"),
            ("redirect_uri", redirectURI)
        ]
        let data = try await postTokenRequest(
            params: params,
            clientSecret: clientSecret,
            session: session,
            failurePrefix: "Token exchange HTTP error"
        )
        return try parseTokenResponse(data, existingRefreshToken: nil)
    }

    /// Obtains a new access token, preserving `refreshToken` if Google does not rotate it.
    public static func refreshAccessToken(
        refreshToken: String,
        clientId: String,
        clientSecret: String? = nil,
        session: URLSession = .shared
    ) async throws -> OAuthTokenSet {
        let params: [(String, String)] = [
            ("client_id", clientId),
            ("refresh_token", refreshToken),
            ("grant_type", "refresh_token")
        ]
        let data = try await postTokenRequest(
            params: params,
            clientSecret: clientSecret,
            session: session,
            failurePrefix: "Token refresh HTTP error"
        )
        return try parseTokenResponse(data, existingRefreshToken: refreshToken)
    }

    // MARK: - Private Helpers

    private static func postTokenRequest(
        params: [(String, String)],
        clientSecret: String?,
        session: URLSession,
        failurePrefix: String
    ) async throws -> Data {
        var request = URLRequest(url: tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        var params = params
        if let clientSecret, !clientSecret.isEmpty {
            params.append(("client_secret", clientSecret))
        }
        request.httpBody = Data(formEncode(params).utf8)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw GoogleDriveError.oauthFailed("\(failurePrefix): \(body)")
        }
        return data
    }

    private static func formEncode(_ pairs: [(String, String)]) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return pairs.map { key, value in
            let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(k)=\(v)"
        }.joined(separator: "&")
    }

    private static func parseTokenResponse(_ data: Data, existingRefreshToken: String?) throws -> OAuthTokenSet {
        struct RawTokenResponse: Decodable {
            let access_token: String
            let refresh_token: String?
            let expires_in: Double?
            let scope: String?
        }
        let decoded = try JSONDecoder().decode(RawTokenResponse.self, from: data)
        return OAuthTokenSet(
            accessToken: decoded.access_token,
            refreshToken: decoded.refresh_token ?? existingRefreshToken,
            expiresAt: Date().addingTimeInterval(decoded.expires_in ?? 3600),
            scope: decoded.scope
        )
    }
}
