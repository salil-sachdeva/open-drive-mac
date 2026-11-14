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

    public func ensureWorkspace(wholeDrive: Bool) async throws -> (rootId: String, trashId: String?, startPageToken: String) {
        let startToken = try await fetchStartPageToken()
        if wholeDrive {
            return (rootId: "root", trashId: nil, startPageToken: startToken)
        }
        let rootId = try await findOrCreateTaggedFolder(
            name: "Open Drive",
            parentId: "root",
            tagKey: "fdRoot"
        )
        let trashId = try await findOrCreateTaggedFolder(
            name: OpenDrivePaths.trashFolderName,
            parentId: rootId,
            tagKey: "fdTrash"
        )
        return (rootId: rootId, trashId: trashId, startPageToken: startToken)
    }

    public func listChildren(folderId: String) async throws -> [DriveItem] {
        var allItems: [DriveItem] = []
        var pageToken: String? = nil

        repeat {
            var comps = URLComponents(url: Self.driveAPIBase.appendingPathComponent("files"), resolvingAgainstBaseURL: false)!
            var queryItems = [
                URLQueryItem(name: "q", value: "'\(folderId)' in parents and trashed = false"),
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
                allItems.append(Self.mapRawFile(raw, defaultParentId: folderId))
            }
            pageToken = decoded.nextPageToken
        } while pageToken != nil

        return allItems
    }

    public func fetchItemMetadata(driveId: String) async throws -> DriveItem? {
        var comps = URLComponents(
            url: Self.driveAPIBase.appendingPathComponent("files").appendingPathComponent(driveId),
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
        var comps = URLComponents(
            url: Self.driveAPIBase.appendingPathComponent("files").appendingPathComponent(driveId),
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
            appProps["fdEnc"] = "1"
            if let origClearName {
                appProps["fdName"] = origClearName
            }
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

    public func renameOrMove(
        driveId: String,
        newName: String?,
        addParentId: String?,
        removeParentId: String?
    ) async throws -> DriveItem {
        var comps = URLComponents(
            url: Self.driveAPIBase.appendingPathComponent("files").appendingPathComponent(driveId),
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
        if let trashFolderId, let currentParentId {
            _ = try await renameOrMove(
                driveId: driveId,
                newName: nil,
                addParentId: trashFolderId,
                removeParentId: currentParentId
            )
            return
        }
        let url = Self.driveAPIBase.appendingPathComponent("files").appendingPathComponent(driveId)
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
            baseURL = Self.uploadAPIBase.appendingPathComponent("files").appendingPathComponent(targetDriveId)
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
            metadata["appProperties"] = ["fdEnc": "1"]
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: metadata)

        let (data, resp) = try await session.data(for: req)
        try validateHTTP(resp, data: data)
        guard let http = resp as? HTTPURLResponse,
              let location = http.value(forHTTPHeaderField: "Location"),
              let sessionURL = URL(string: location) else {
            throw GoogleDriveError.invalidResponse("Missing Location header in resumable upload response")
        }
        return sessionURL
    }

    public func uploadResumableChunk(
        sessionURL: URL,
        chunkData: Data,
        offset: Int64,
        totalSize: Int64
    ) async throws -> (nextOffset: Int64, completedItem: DriveItem?) {
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
        comps.queryItems = [
            URLQueryItem(
                name: "q",
                value: "'\(rootId)' in parents and name = '\(OpenDrivePaths.metaFileName)' and trashed = false"
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
        comps.queryItems = [
            URLQueryItem(
                name: "q",
                value: "mimeType = '\(Self.folderMimeType)' and trashed = false and appProperties has { key='\(tagKey)' and value='1' }"
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
        let isEnc = raw.appProperties?["fdEnc"] == "1"
        let rawSize = raw.size.flatMap { Int64($0) } ?? 0
        let logicalSize: Int64
        if isEnc && !isFolder && rawSize >= Int64(VaultCrypto.headerSize + VaultCrypto.gcmTagSize) {
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
            name: isEnc ? (raw.appProperties?["fdName"] ?? raw.name) : raw.name,
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
            appAuthorized: raw.capabilities?.canEdit ?? true
        )
    }
}
