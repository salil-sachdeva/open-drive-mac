import Foundation
import Security

/// Shared credential store backed by macOS Keychain (with fallback to encrypted/local file in test environments).
/// Stores Google OAuth tokens and unlocked `FDE1` vault Master Keys so both `OpenDriveApp` and `OpenDriveFS` can read them.
public struct OAuthTokenSet: Codable, Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date
    public var scope: String?

    public init(accessToken: String, refreshToken: String?, expiresAt: Date, scope: String? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.scope = scope
    }

    public var isExpiredOrExpiringSoon: Bool {
        Date().addingTimeInterval(60) >= expiresAt
    }
}

public actor KeychainStore {
    public static let shared = KeychainStore()

    private let service: String
    private let fallbackDirectory: URL?

    public init(service: String = "com.opendrive.shared", fallbackDirectory: URL? = nil) {
        self.service = service
        self.fallbackDirectory = fallbackDirectory
    }

    // MARK: - OAuth Tokens

    public func saveOAuthTokens(_ tokens: OAuthTokenSet, for accountId: String) throws {
        let data = try JSONEncoder().encode(tokens)
        try writeData(data, account: "oauth.google.\(accountId)")
    }

    public func loadOAuthTokens(for accountId: String) throws -> OAuthTokenSet? {
        guard let data = try readData(account: "oauth.google.\(accountId)") else {
            return nil
        }
        return try JSONDecoder().decode(OAuthTokenSet.self, from: data)
    }

    public func deleteOAuthTokens(for accountId: String) throws {
        try deleteData(account: "oauth.google.\(accountId)")
    }

    // MARK: - Unlocked Vault Master Key (`crypto.masterKey.google.<accountId>`)

    public func saveMasterKey(_ masterKeyData: Data, for accountId: String) throws {
        try writeData(masterKeyData, account: "crypto.masterKey.google.\(accountId)")
    }

    public func loadMasterKey(for accountId: String) throws -> Data? {
        try readData(account: "crypto.masterKey.google.\(accountId)")
    }

    public func deleteMasterKey(for accountId: String) throws {
        try deleteData(account: "crypto.masterKey.google.\(accountId)")
    }

    // MARK: - Raw Keychain / File Operations

    private func writeData(_ data: Data, account: String) throws {
        if let fallbackDirectory {
            try FileManager.default.createDirectory(at: fallbackDirectory, withIntermediateDirectories: true)
            let fileURL = fallbackDirectory.appendingPathComponent(account)
            try data.write(to: fileURL, options: .atomic)
            return
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [
                NSLocalizedDescriptionKey: "Keychain write failed (\(status)) for \(account)"
            ])
        }
    }

    private func readData(account: String) throws -> Data? {
        if let fallbackDirectory {
            let fileURL = fallbackDirectory.appendingPathComponent(account)
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
            return try Data(contentsOf: fileURL)
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = item as? Data else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [
                NSLocalizedDescriptionKey: "Keychain read failed (\(status)) for \(account)"
            ])
        }
        return data
    }

    private func deleteData(account: String) throws {
        if let fallbackDirectory {
            let fileURL = fallbackDirectory.appendingPathComponent(account)
            try? FileManager.default.removeItem(at: fileURL)
            return
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }
}
