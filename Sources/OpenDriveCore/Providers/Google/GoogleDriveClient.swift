import Foundation

/// Google Drive REST API v3 client conforming to `CloudDrive`.
public actor GoogleDriveClient: CloudDrive {
    public static let driveAPIBase = URL(string: "https://www.googleapis.com/drive/v3")!
    public static let uploadAPIBase = URL(string: "https://www.googleapis.com/upload/drive/v3")!
    public static let folderMimeType = "application/vnd.google-apps.folder"
    public static let fileFields = "id,name,mimeType,size,md5Checksum,version,modifiedTime,trashed,parents,appProperties,capabilities(canEdit)"

    public let accountId: String
    public let clientId: String
    public let clientSecret: String?
    private let keychain: KeychainStore
    private let session: URLSession

    public init(
        accountId: String,
        clientId: String,
        clientSecret: String? = nil,
        keychain: KeychainStore = .shared,
        session: URLSession = .shared
    ) {
        self.accountId = accountId
        self.clientId = clientId
        self.clientSecret = clientSecret
        self.keychain = keychain
        self.session = session
    }

    // MARK: - Authenticated Requests

    private func validAccessToken() async throws -> String {
        guard var tokens = try await keychain.loadOAuthTokens(for: accountId) else {
            throw GoogleDriveError.missingCredentials
        }
        if tokens.isExpiredOrExpiringSoon, let refresh = tokens.refreshToken {
            tokens = try await GoogleOAuth.refreshAccessToken(
                refreshToken: refresh,
                clientId: clientId,
                clientSecret: clientSecret,
                session: session
            )
            try await keychain.saveOAuthTokens(tokens, for: accountId)
        }
        return tokens.accessToken
    }

    private func authorizedRequest(url: URL, method: String = "GET") async throws -> URLRequest {
        let token = try await validAccessToken()
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    // MARK: - Input Validation & Query Hygiene

    public static func escapeQueryLiteral(_ value: String) -> String {
        let stripped = String(value.unicodeScalars.filter { scalar in
            !(scalar.value < 0x20 || scalar.value == 0x7F)
        })
        return stripped
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
    }

    @discardableResult
    public static func validateDriveId(_ driveId: String) throws -> String {
        guard !driveId.isEmpty,
              driveId.count <= 256,
              !driveId.contains(".."),
              !driveId.contains("/"),
              !driveId.contains("\\"),
              !driveId.contains("?"),
              !driveId.contains("#"),
              !driveId.contains("%"),
              driveId.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              driveId.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F }) else {
            throw GoogleDriveError.invalidResponse("Invalid Google Drive identifier")
        }
        return driveId
    }

    public static func validateResumableUploadURL(_ url: URL) throws {
        guard url.scheme?.lowercased() == "https",
              url.user == nil,
              url.password == nil,
              let host = url.host?.lowercased(),
              !host.hasPrefix("."),
              (host == "www.googleapis.com" || host == "upload.googleapis.com" || host.hasSuffix(".googleapis.com")) else {
            throw GoogleDriveError.invalidResponse("Untrusted resumable upload session URL")
        }
    }

    // MARK: - CloudDrive Conformance

    public func fetchUserEmail() async throws -> String {
        var comps = URLComponents(url: Self.driveAPIBase.appendingPathComponent("about"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "fields", value: "user(emailAddress)")]
        let req = try await authorizedRequest(url: comps.url!)
        let (data, resp) = try await session.data(for: req)
        try validateHTTP(resp, data: data)

        struct AboutResponse: Decodable {
            struct User: Decodable { let emailAddress: String }
            let user: User
        }
        return try JSONDecoder().decode(AboutResponse.self, from: data).user.emailAddress
    }

    public func fetchStorageQuota() async throws -> CloudStorageQuota? {
        var comps = URLComponents(url: Self.driveAPIBase.appendingPathComponent("about"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "fields", value: "storageQuota(limit,usage)")]
        let req = try await authorizedRequest(url: comps.url!)
        let (data, resp) = try await session.data(for: req)
        try validateHTTP(resp, data: data)

        struct QuotaResponse: Decodable {
            struct StorageQuota: Decodable {
                let limit: String?
                let usage: String?
            }
            let storageQuota: StorageQuota?
        }
        let decoded = try JSONDecoder().decode(QuotaResponse.self, from: data)
        guard let sq = decoded.storageQuota else { return nil }
        return CloudStorageQuota(
            limit: sq.limit.flatMap { Int64($0) },
            usage: sq.usage.flatMap { Int64($0) }
        )
    }

    public func resolveRootFolderId() async throws -> String {
        var comps = URLComponents(
            url: Self.driveAPIBase.appendingPathComponent("files").appendingPathComponent("root"),
            resolvingAgainstBaseURL: false
        )!
        comps.queryItems = [URLQueryItem(name: "fields", value: "id")]
        let req = try await authorizedRequest(url: comps.url!)
        let (data, resp) = try await session.data(for: req)
        try validateHTTP(resp, data: data)
        struct RootResponse: Decodable { let id: String }
        return try JSONDecoder().decode(RootResponse.self, from: data).id
    }

    public func ensureWorkspace(wholeDrive: Bool) async throws -> (rootId: String, trashId: String?, startPageToken: String) {
        let startToken = try await fetchStartPageToken()
        if wholeDrive {
            let canonicalRootId = (try? await resolveRootFolderId()) ?? "root"
            return (rootId: canonicalRootId, trashId: nil, startPageToken: startToken)
        }
        let rootId = try await findOrCreateTaggedFolder(
            name: "Open Drive",
            parentId: "root",
            tagKey: "odRoot"
        )
        let trashId = try await findOrCreateTaggedFolder(
            name: OpenDrivePaths.trashFolderName,
            parentId: rootId,
            tagKey: "odTrash"
        )
        return (rootId: rootId, trashId: trashId, startPageToken: startToken)
    }

    public func listChildren(folderId: String) async throws -> [DriveItem] {
        var allItems: [DriveItem] = []
        var pageToken: String? = nil

        repeat {
            var comps = URLComponents(url: Self.driveAPIBase.appendingPathComponent("files"), resolvingAgainstBaseURL: false)!
            let safeFolderId = Self.escapeQueryLiteral(folderId)
            var queryItems = [
                URLQueryItem(name: "q", value: "'\(safeFolderId)' in parents and trashed = false"),
                URLQueryItem(name: "pageSize", value: "500"),
                URLQueryItem(name: "fields", value: "nextPageToken,files(\(Self.fileFields))")
            ]
            if let pageToken {
                queryItems.append(URLQueryItem(name: "pageToken", value: pageToken))
            }
            comps.queryItems = queryItems

            let req = try await authorizedRequest(url: comps.url!)
            let (data, resp) = try await session.data(for: req)
            try validateHTTP(resp, data: data)

            let decoded = try JSONDecoder().decode(FileListResponse.self, from: data)
            for raw in decoded.files {
                var mapped = Self.mapRawFile(raw, defaultParentId: folderId)
                if mapped.isGoogleWorkspaceVirtualDocument {
                    continue
                }
                if folderId == "root" {
                    mapped.parentId = "root"
                }
                allItems.append(mapped)
            }
            pageToken = decoded.nextPageToken
        } while pageToken != nil

        return allItems
    }

    public func fetchItemMetadata(driveId: String) async throws -> DriveItem? {
        let safeDriveId = try Self.validateDriveId(driveId)
        var comps = URLComponents(
            url: Self.driveAPIBase.appendingPathComponent("files").appendingPathComponent(safeDriveId),
            resolvingAgainstBaseURL: false
        )!
        comps.queryItems = [URLQueryItem(name: "fields", value: Self.fileFields)]
        let req = try await authorizedRequest(url: comps.url!)
        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode == 404 {
            return nil
        }
        try validateHTTP(resp, data: data)
        let raw = try JSONDecoder().decode(RawDriveFile.self, from: data)
        return Self.mapRawFile(raw, defaultParentId: raw.parents?.first)
    }

    public func fetchChanges(pageToken: String) async throws -> RemoteDeltaPage {
        var comps = URLComponents(url: Self.driveAPIBase.appendingPathComponent("changes"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "pageToken", value: pageToken),
            URLQueryItem(name: "pageSize", value: "500"),
            URLQueryItem(name: "fields", value: "nextPageToken,newStartPageToken,changes(fileId,removed,file(\(Self.fileFields)))")
        ]
        let req = try await authorizedRequest(url: comps.url!)
        let (data, resp) = try await session.data(for: req)
        try validateHTTP(resp, data: data)

        let decoded = try JSONDecoder().decode(ChangesListResponse.self, from: data)
        let events: [RemoteChangeEvent] = decoded.changes.map { ch in
            let mapped = ch.file.map { Self.mapRawFile($0, defaultParentId: $0.parents?.first) }
            let isRemoved = (ch.removed ?? false) || (ch.file?.trashed ?? false)
            return RemoteChangeEvent(driveId: ch.fileId, removed: isRemoved, item: mapped)
        }
        return RemoteDeltaPage(
            events: events,
            nextPageToken: decoded.nextPageToken,
            newStartPageToken: decoded.newStartPageToken
        )
    }

    public func downloadByteRange(driveId: String, offset: Int64, length: Int) async throws -> Data {
        guard length > 0 else { return Data() }
        let safeDriveId = try Self.validateDriveId(driveId)
        var comps = URLComponents(
            url: Self.driveAPIBase.appendingPathComponent("files").appendingPathComponent(safeDriveId),
            resolvingAgainstBaseURL: false
        )!
        comps.queryItems = [URLQueryItem(name: "alt", value: "media")]

        var req = try await authorizedRequest(url: comps.url!)
        let endByte = offset + Int64(length) - 1
        req.setValue("bytes=\(offset)-\(endByte)", forHTTPHeaderField: "Range")

        let (data, resp) = try await session.data(for: req)
        try validateHTTP(resp, data: data)
        return data
    }

    public func createFolder(
        name: String,
        parentId: String,
        isEncrypted: Bool = false,
        origClearName: String? = nil
    ) async throws -> DriveItem {
        let url = URL(string: "\(Self.driveAPIBase.absoluteString)/files?fields=\(Self.fileFields)")!
        var req = try await authorizedRequest(url: url, method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var appProps: [String: String] = [:]
        if isEncrypted {
            appProps["odEnc"] = "1"
        }
        let payload: [String: Any] = [
            "name": name,
            "mimeType": Self.folderMimeType,
            "parents": [parentId],
            "appProperties": appProps
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, resp) = try await session.data(for: req)
        try validateHTTP(resp, data: data)
        let raw = try JSONDecoder().decode(RawDriveFile.self, from: data)
        return Self.mapRawFile(raw, defaultParentId: parentId)
    }

    public func updatePosixMode(driveId: String, mode: UInt32) async throws {
        let safeDriveId = try Self.validateDriveId(driveId)
        let url = Self.driveAPIBase.appendingPathComponent("files").appendingPathComponent(safeDriveId)
        var req = try await authorizedRequest(url: url, method: "PATCH")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let octal = String(mode & 0o0777, radix: 8)
        let body: [String: Any] = ["appProperties": ["odMode": octal]]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await session.data(for: req)
        try validateHTTP(resp, data: data)
    }

    public func createSymlink(
        name: String,
        target: String,
        parentId: String,
        isEncrypted: Bool = false,
        origClearName: String? = nil
    ) async throws -> DriveItem {
        let url = URL(string: "\(Self.driveAPIBase.absoluteString)/files?fields=\(Self.fileFields)")!
        var req = try await authorizedRequest(url: url, method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let targetBytes = Data(target.utf8)
        let inlineTarget = targetBytes.count <= 100
        var appProps: [String: String] = ["odMode": "777"]
        if inlineTarget {
            appProps["odSymlink"] = target
        } else {
            appProps["odSymlinkBody"] = "1"
        }
        if isEncrypted {
            appProps["odEnc"] = "1"
            appProps["odSymlinkEnc"] = "1"
        }

        let payload: [String: Any] = [
            "name": name,
            "mimeType": "application/x-symlink",
            "parents": [parentId],
            "appProperties": appProps
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, resp) = try await session.data(for: req)
        try validateHTTP(resp, data: data)
        let raw = try JSONDecoder().decode(RawDriveFile.self, from: data)
        var mapped = Self.mapRawFile(raw, defaultParentId: parentId)

        if !inlineTarget {
            let sessionURL = try await startResumableUpload(
                name: name,
                parentId: parentId,
                targetDriveId: mapped.driveId,
                mime: "application/x-symlink",
                totalSize: Int64(targetBytes.count),
                isEncrypted: isEncrypted
            )
            let (_, completed) = try await uploadResumableChunk(
                sessionURL: sessionURL,
                chunkData: targetBytes,
                offset: 0,
                totalSize: Int64(targetBytes.count)
            )
            if let completed {
                mapped = completed
            }
        }

        mapped.symlinkTarget = target
        mapped.posixMode = 0o777
        mapped.size = Int64(targetBytes.count)
        return mapped
    }

    public func renameOrMove(
        driveId: String,
        newName: String?,
        addParentId: String?,
        removeParentId: String?
    ) async throws -> DriveItem {
        let safeDriveId = try Self.validateDriveId(driveId)
        var comps = URLComponents(
            url: Self.driveAPIBase.appendingPathComponent("files").appendingPathComponent(safeDriveId),
            resolvingAgainstBaseURL: false
        )!
        var q: [URLQueryItem] = [URLQueryItem(name: "fields", value: Self.fileFields)]
        if let addParentId {
            q.append(URLQueryItem(name: "addParents", value: addParentId))
        }
        if let removeParentId {
            q.append(URLQueryItem(name: "removeParents", value: removeParentId))
        }
        comps.queryItems = q

        var req = try await authorizedRequest(url: comps.url!, method: "PATCH")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = [:]
        if let newName {
            body["name"] = newName
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await session.data(for: req)
        try validateHTTP(resp, data: data)
        let raw = try JSONDecoder().decode(RawDriveFile.self, from: data)
        return Self.mapRawFile(raw, defaultParentId: addParentId ?? raw.parents?.first)
    }

    public func moveToTrash(
        driveId: String,
        trashFolderId: String?,
        currentParentId: String?
    ) async throws {
        let safeDriveId = try Self.validateDriveId(driveId)
        if let trashFolderId, let currentParentId {
            _ = try await renameOrMove(
                driveId: safeDriveId,
                newName: nil,
                addParentId: trashFolderId,
                removeParentId: currentParentId
            )
            return
        }
        let url = Self.driveAPIBase.appendingPathComponent("files").appendingPathComponent(safeDriveId)
        var req = try await authorizedRequest(url: url, method: "PATCH")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["trashed": true])
        let (data, resp) = try await session.data(for: req)
        try validateHTTP(resp, data: data)
    }

    public func startResumableUpload(
        name: String,
        parentId: String,
        targetDriveId: String?,
        mime: String,
        totalSize: Int64,
        isEncrypted: Bool
    ) async throws -> URL {
        let baseURL: URL
        let method: String
        if let targetDriveId {
            let safeTargetId = try Self.validateDriveId(targetDriveId)
            baseURL = Self.uploadAPIBase.appendingPathComponent("files").appendingPathComponent(safeTargetId)
            method = "PATCH"
        } else {
            baseURL = Self.uploadAPIBase.appendingPathComponent("files")
            method = "POST"
        }
        var comps = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "uploadType", value: "resumable"),
            URLQueryItem(name: "fields", value: Self.fileFields)
        ]

        var req = try await authorizedRequest(url: comps.url!, method: method)
        req.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        req.setValue(mime, forHTTPHeaderField: "X-Upload-Content-Type")
        req.setValue("\(totalSize)", forHTTPHeaderField: "X-Upload-Content-Length")

        var metadata: [String: Any] = ["name": name]
        if targetDriveId == nil {
            metadata["parents"] = [parentId]
        }
        if isEncrypted {
            metadata["appProperties"] = ["odEnc": "1"]
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: metadata)

        let (data, resp) = try await session.data(for: req)
        try validateHTTP(resp, data: data)
        guard let http = resp as? HTTPURLResponse,
              let location = http.value(forHTTPHeaderField: "Location"),
              let sessionURL = URL(string: location) else {
            throw GoogleDriveError.invalidResponse("Missing Location header in resumable upload response")
        }
        try Self.validateResumableUploadURL(sessionURL)
        return sessionURL
    }

    public func uploadResumableChunk(
        sessionURL: URL,
        chunkData: Data,
        offset: Int64,
        totalSize: Int64
    ) async throws -> (nextOffset: Int64, completedItem: DriveItem?) {
        try Self.validateResumableUploadURL(sessionURL)
        var req = URLRequest(url: sessionURL)
        req.httpMethod = "PUT"
        req.httpBody = chunkData
        req.setValue("\(chunkData.count)", forHTTPHeaderField: "Content-Length")

        if totalSize == 0 {
            req.setValue("bytes */0", forHTTPHeaderField: "Content-Range")
        } else {
            let endByte = offset + Int64(chunkData.count) - 1
            req.setValue("bytes \(offset)-\(endByte)/\(totalSize)", forHTTPHeaderField: "Content-Range")
        }

        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw GoogleDriveError.invalidResponse("Non-HTTP response")
        }

        if http.statusCode == 308 {
            if let rangeHeader = http.value(forHTTPHeaderField: "Range"),
               let dashIdx = rangeHeader.lastIndex(of: "-"),
               let lastByte = Int64(rangeHeader[rangeHeader.index(after: dashIdx)...]) {
                return (nextOffset: lastByte + 1, completedItem: nil)
            }
            return (nextOffset: offset + Int64(chunkData.count), completedItem: nil)
        }

        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw GoogleDriveError.httpError(http.statusCode, body)
        }
        let raw = try JSONDecoder().decode(RawDriveFile.self, from: data)
        let item = Self.mapRawFile(raw, defaultParentId: raw.parents?.first)
        return (nextOffset: totalSize, completedItem: item)
    }

    public func fetchKeyBundle(rootId: String) async throws -> (metaDriveId: String, bundle: KeyBundle)? {
        var comps = URLComponents(url: Self.driveAPIBase.appendingPathComponent("files"), resolvingAgainstBaseURL: false)!
        let safeRootId = Self.escapeQueryLiteral(rootId)
        let safeMetaName = Self.escapeQueryLiteral(OpenDrivePaths.metaFileName)
        comps.queryItems = [
            URLQueryItem(
                name: "q",
                value: "'\(safeRootId)' in parents and name = '\(safeMetaName)' and trashed = false"
            ),
            URLQueryItem(name: "fields", value: "files(id,name,size)")
        ]
        let req = try await authorizedRequest(url: comps.url!)
        let (data, resp) = try await session.data(for: req)
        try validateHTTP(resp, data: data)

        struct MetaLookupResponse: Decodable {
            struct Entry: Decodable {
                let id: String
                let size: String?
            }
            let files: [Entry]
        }
        let found = try JSONDecoder().decode(MetaLookupResponse.self, from: data)
        guard let metaEntry = found.files.first else {
            return nil
        }

        let size = metaEntry.size.flatMap { Int($0) } ?? 16_384
        let rawMeta = try await downloadByteRange(driveId: metaEntry.id, offset: 0, length: max(1024, size))
        let bundle = try JSONDecoder().decode(KeyBundle.self, from: rawMeta)
        return (metaDriveId: metaEntry.id, bundle: bundle)
    }

    public func uploadKeyBundle(_ bundle: KeyBundle, rootId: String, existingMetaId: String?) async throws -> String {
        let encoded = try JSONEncoder().encode(bundle)
        let sessionURL = try await startResumableUpload(
            name: OpenDrivePaths.metaFileName,
            parentId: rootId,
            targetDriveId: existingMetaId,
            mime: "application/json",
            totalSize: Int64(encoded.count),
            isEncrypted: false
        )
        let (_, completed) = try await uploadResumableChunk(
            sessionURL: sessionURL,
            chunkData: encoded,
            offset: 0,
            totalSize: Int64(encoded.count)
        )
        return completed?.driveId ?? existingMetaId ?? OpenDrivePaths.metaFileName
    }

    // MARK: - Private Helpers & Wire Models

    private func fetchStartPageToken() async throws -> String {
        let url = Self.driveAPIBase.appendingPathComponent("changes").appendingPathComponent("startPageToken")
        let req = try await authorizedRequest(url: url)
        let (data, resp) = try await session.data(for: req)
        try validateHTTP(resp, data: data)
        struct StartTokenResponse: Decodable { let startPageToken: String }
        return try JSONDecoder().decode(StartTokenResponse.self, from: data).startPageToken
    }

    private func findOrCreateTaggedFolder(name: String, parentId: String, tagKey: String) async throws -> String {
        var comps = URLComponents(url: Self.driveAPIBase.appendingPathComponent("files"), resolvingAgainstBaseURL: false)!
        let safeMime = Self.escapeQueryLiteral(Self.folderMimeType)
        let safeTagKey = Self.escapeQueryLiteral(tagKey)
        comps.queryItems = [
            URLQueryItem(
                name: "q",
                value: "mimeType = '\(safeMime)' and trashed = false and appProperties has { key='\(safeTagKey)' and value='1' }"
            ),
            URLQueryItem(name: "fields", value: "files(id,name)")
        ]
        let req = try await authorizedRequest(url: comps.url!)
        let (data, resp) = try await session.data(for: req)
        try validateHTTP(resp, data: data)

        struct LookupResponse: Decodable {
            struct Entry: Decodable { let id: String }
            let files: [Entry]
        }
        let existing = try JSONDecoder().decode(LookupResponse.self, from: data)
        if let first = existing.files.first {
            return first.id
        }

        let createURL = URL(string: "\(Self.driveAPIBase.absoluteString)/files?fields=id")!
        var createReq = try await authorizedRequest(url: createURL, method: "POST")
        createReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "name": name,
            "mimeType": Self.folderMimeType,
            "parents": [parentId],
            "appProperties": [tagKey: "1"]
        ]
        createReq.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (createData, createResp) = try await session.data(for: createReq)
        try validateHTTP(createResp, data: createData)
        struct Created: Decodable { let id: String }
        return try JSONDecoder().decode(Created.self, from: createData).id
    }

    private func validateHTTP(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw GoogleDriveError.invalidResponse("Non-HTTP URLResponse")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw GoogleDriveError.httpError(http.statusCode, body)
        }
    }

    private struct RawDriveFile: Decodable {
        struct Capabilities: Decodable {
            let canEdit: Bool?
        }
        let id: String
        let name: String
        let mimeType: String?
        let size: String?
        let md5Checksum: String?
        let version: String?
        let modifiedTime: String?
        let trashed: Bool?
        let parents: [String]?
        let appProperties: [String: String]?
        let capabilities: Capabilities?
    }

    private struct FileListResponse: Decodable {
        let nextPageToken: String?
        let files: [RawDriveFile]
    }

    private struct ChangesListResponse: Decodable {
        struct ChangeEntry: Decodable {
            let fileId: String
            let removed: Bool?
            let file: RawDriveFile?
        }
        let nextPageToken: String?
        let newStartPageToken: String?
        let changes: [ChangeEntry]
    }

    private static func mapRawFile(_ raw: RawDriveFile, defaultParentId: String?) -> DriveItem {
        let isFolder = raw.mimeType == folderMimeType
        let isEnc = raw.appProperties?["odEnc"] == "1"
        let parsedMode = raw.appProperties?["odMode"].flatMap { UInt32($0, radix: 8) }.map { $0 & 0o0777 }
        let inlineSymlink = raw.appProperties?["odSymlink"]
        let bodySymlink = raw.mimeType == "application/x-symlink" && raw.appProperties?["odSymlinkBody"] == "1"
        let resolvedSymlinkTarget: String? = inlineSymlink ?? (bodySymlink ? "" : nil)
        let rawSize = raw.size.flatMap { Int64($0) } ?? 0
        let logicalSize: Int64
        if let sym = inlineSymlink {
            logicalSize = Int64(sym.utf8.count)
        } else if bodySymlink {
            logicalSize = rawSize
        } else if isEnc && !isFolder && rawSize >= Int64(VaultCrypto.headerSize + VaultCrypto.gcmTagSize) {
            let bodyBytes = rawSize - Int64(VaultCrypto.headerSize)
            let wireChunk = Int64(OpenDrivePaths.defaultChunkSize + VaultCrypto.gcmTagSize)
            let fullChunks = bodyBytes / wireChunk
            let remainder = bodyBytes % wireChunk
            let remPlain = remainder > Int64(VaultCrypto.gcmTagSize) ? (remainder - Int64(VaultCrypto.gcmTagSize)) : 0
            logicalSize = fullChunks * Int64(OpenDrivePaths.defaultChunkSize) + remPlain
        } else {
            logicalSize = rawSize
        }

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fallbackFormatter = ISO8601DateFormatter()
        let mtime = raw.modifiedTime.flatMap {
            isoFormatter.date(from: $0) ?? fallbackFormatter.date(from: $0)
        }?.timeIntervalSince1970 ?? Date().timeIntervalSince1970

        return DriveItem(
            driveId: raw.id,
            parentId: raw.parents?.first ?? defaultParentId,
            name: isEnc ? (raw.appProperties?["odName"] ?? raw.name) : raw.name,
            encName: isEnc ? raw.name : nil,
            isFolder: isFolder,
            size: logicalSize,
            mime: raw.mimeType ?? "application/octet-stream",
            md5: raw.md5Checksum,
            version: raw.version,
            modifiedTime: mtime,
            isEncrypted: isEnc,
            pinned: false,
            trashedAt: (raw.trashed ?? false) ? mtime : nil,
            appAuthorized: raw.capabilities?.canEdit ?? true,
            posixMode: parsedMode,
            symlinkTarget: resolvedSymlinkTarget
        )
    }
}
