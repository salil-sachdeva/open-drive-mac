import Foundation
import Security

/// Shared credential store backed by macOS Keychain (with fallback to encrypted/local file in test environments).
/// Stores Google OAuth tokens and unlocked `ODE1` vault Master Keys so both `OpenDriveApp` and `OpenDriveFS` can read them.
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
    public let accessGroup: String?
    private let fallbackDirectory: URL?

    public init(
        service: String = "com.opendrive.shared",
        accessGroup: String? = OpenDrivePaths.keychainAccessGroup,
        fallbackDirectory: URL? = nil
    ) {
        self.service = service
        self.accessGroup = accessGroup
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

    private func baseQuery(account: String, includeAccessGroup: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        if includeAccessGroup, let accessGroup, !accessGroup.isEmpty {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }

    private func writeData(_ data: Data, account: String) throws {
        if let fallbackDirectory {
            let safeAccount = OpenDrivePaths.sanitizeAccountId(account)
            let fileURL = fallbackDirectory.appendingPathComponent(safeAccount)
            try OpenDrivePaths.writePrivateFile(data, to: fileURL)
            return
        }

        if let accessGroup, !accessGroup.isEmpty {
            let groupStatus = writeKeychainItem(data: data, account: account, includeAccessGroup: true)
            if groupStatus == errSecSuccess {
                return
            }
            // Ad-hoc signed builds lack keychain-access-group entitlement; fall back to default keychain scope.
            if groupStatus != errSecMissingEntitlement {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(groupStatus), userInfo: [
                    NSLocalizedDescriptionKey: "Keychain write failed (\(groupStatus)) for \(account)"
                ])
            }
        }

        let status = writeKeychainItem(data: data, account: account, includeAccessGroup: false)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [
                NSLocalizedDescriptionKey: "Keychain write failed (\(status)) for \(account)"
            ])
        }
    }

    private func writeKeychainItem(data: Data, account: String, includeAccessGroup: Bool) -> OSStatus {
        let query = baseQuery(account: account, includeAccessGroup: includeAccessGroup)
        SecItemDelete(query as CFDictionary)

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(addQuery as CFDictionary, nil)
    }

    private func readData(account: String) throws -> Data? {
        if let fallbackDirectory {
            let safeAccount = OpenDrivePaths.sanitizeAccountId(account)
            let fileURL = fallbackDirectory.appendingPathComponent(safeAccount)
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
            return try Data(contentsOf: fileURL)
        }

        if let accessGroup, !accessGroup.isEmpty {
            let (status, data) = readKeychainItem(account: account, includeAccessGroup: true)
            if status == errSecSuccess {
                return data
            }
            if status != errSecMissingEntitlement && status != errSecItemNotFound {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [
                    NSLocalizedDescriptionKey: "Keychain read failed (\(status)) for \(account)"
                ])
            }
        }

        let (status, data) = readKeychainItem(account: account, includeAccessGroup: false)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [
                NSLocalizedDescriptionKey: "Keychain read failed (\(status)) for \(account)"
            ])
        }
        return data
    }

    private func readKeychainItem(account: String, includeAccessGroup: Bool) -> (OSStatus, Data?) {
        var query = baseQuery(account: account, includeAccessGroup: includeAccessGroup)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        return (status, item as? Data)
    }

    private func deleteData(account: String) throws {
        if let fallbackDirectory {
            let safeAccount = OpenDrivePaths.sanitizeAccountId(account)
            let fileURL = fallbackDirectory.appendingPathComponent(safeAccount)
            try? FileManager.default.removeItem(at: fileURL)
            return
        }

        if let accessGroup, !accessGroup.isEmpty {
            let groupQuery = baseQuery(account: account, includeAccessGroup: true)
            let groupStatus = SecItemDelete(groupQuery as CFDictionary)
            if groupStatus != errSecSuccess && groupStatus != errSecItemNotFound && groupStatus != errSecMissingEntitlement {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(groupStatus))
            }
        }

        let query = baseQuery(account: account, includeAccessGroup: false)
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }
}
