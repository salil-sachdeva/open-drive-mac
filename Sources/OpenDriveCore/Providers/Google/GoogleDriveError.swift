import Foundation

/// Errors raised by the Google OAuth flow and Drive API client.
public enum GoogleDriveError: Error, LocalizedError {
    case oauthFailed(String)
    case missingCredentials
    case httpError(Int, String)
    case invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case .oauthFailed(let msg): return "Google OAuth error: \(msg)"
        case .missingCredentials: return "Missing Google OAuth credentials in Keychain"
        case .httpError(let status, let body): return "Google Drive API HTTP \(status): \(body)"
        case .invalidResponse(let msg): return "Invalid Google Drive response: \(msg)"
        }
    }
}
