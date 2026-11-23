@preconcurrency import FileProvider
import Foundation
import os
import UniformTypeIdentifiers

private let fpLogger = Logger(subsystem: "org.opendrive.mac.fileprovider", category: "Extension")

// MARK: - Bridge Wire DTO

private struct FPBridgeItem: Codable, Sendable {
    let id: String
    let parentId: String
    let name: String
    let isFolder: Bool
    let size: Int64
    let modifiedTime: Double
    let versionToken: String
    let quotaLabel: String?
}

private struct FPAnchorPayload: Codable, Sendable {
    let anchor: String
}

// MARK: - Bridge HTTP Client

private final class FPBridgeClient: @unchecked Sendable {
    let port: Int
    let token: String
    private let session: URLSession

    init(port: Int, token: String) {
        self.port = port
        self.token = token
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        self.session = URLSession(configuration: config)
    }

    func invalidate() {
        session.invalidateAndCancel()
    }

    func fetchSyncAnchor() async throws -> String {
        let data = try await sendRequest(
            method: "GET",
            path: "/_od_fp/anchor",
            query: []
        )
        return try JSONDecoder().decode(FPAnchorPayload.self, from: data).anchor
    }

    func fetchItem(id: String) async throws -> FPBridgeItem {
        let data = try await sendRequest(
            method: "GET",
            path: "/_od_fp/item",
            query: [URLQueryItem(name: "id", value: id)]
        )
        return try JSONDecoder().decode(FPBridgeItem.self, from: data)
    }

    func listChildren(parentId: String) async throws -> [FPBridgeItem] {
        let data = try await sendRequest(
            method: "GET",
            path: "/_od_fp/children",
            query: [URLQueryItem(name: "parentId", value: parentId)]
        )
        return try JSONDecoder().decode([FPBridgeItem].self, from: data)
    }

    func downloadContent(id: String) async throws -> URL {
        let url = try buildURL(path: "/_od_fp/content", query: [URLQueryItem(name: "id", value: id)])
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (tempURL, resp): (URL, URLResponse)
        do {
            (tempURL, resp) = try await session.download(for: req)
        } catch {
            throw NSFileProviderError(.serverUnreachable)
        }
        try validateHTTP(resp)

        let stagedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("od-fp-\(UUID().uuidString)")
        try? FileManager.default.removeItem(at: stagedURL)
        try FileManager.default.moveItem(at: tempURL, to: stagedURL)
        return stagedURL
    }

    func createItem(parentId: String, name: String, isFolder: Bool, contentURL: URL?) async throws -> FPBridgeItem {
        let body = try contentURL.map { try Data(contentsOf: $0) } ?? Data()
        let data = try await sendRequest(
            method: "POST",
            path: "/_od_fp/create",
            query: [
                URLQueryItem(name: "parentId", value: parentId),
                URLQueryItem(name: "name", value: name),
                URLQueryItem(name: "isFolder", value: isFolder ? "1" : "0")
            ],
            body: body
        )
        return try JSONDecoder().decode(FPBridgeItem.self, from: data)
    }

    func modifyItem(id: String, newParentId: String?, newName: String?, contentURL: URL?) async throws -> FPBridgeItem {
        let body = try contentURL.map { try Data(contentsOf: $0) }
        var query = [URLQueryItem(name: "id", value: id)]
        if let newParentId {
            query.append(URLQueryItem(name: "parentId", value: newParentId))
        }
        if let newName {
            query.append(URLQueryItem(name: "name", value: newName))
        }
        if body != nil {
            query.append(URLQueryItem(name: "hasContent", value: "1"))
        }
        let data = try await sendRequest(
            method: "POST",
            path: "/_od_fp/modify",
            query: query,
            body: body
        )
        return try JSONDecoder().decode(FPBridgeItem.self, from: data)
    }

    func deleteItem(id: String) async throws {
        _ = try await sendRequest(
            method: "DELETE",
            path: "/_od_fp/item",
            query: [URLQueryItem(name: "id", value: id)]
        )
    }

    private func buildURL(path: String, query: [URLQueryItem]) throws -> URL {
        guard port > 0, !token.isEmpty else {
            throw NSFileProviderError(.serverUnreachable)
        }
        var comps = URLComponents()
        comps.scheme = "http"
        comps.host = "127.0.0.1"
        comps.port = port
        comps.path = path
        if !query.isEmpty {
            comps.queryItems = query
        }
        guard let url = comps.url else {
            throw NSFileProviderError(.serverUnreachable)
        }
        return url
    }

    private func sendRequest(
        method: String,
        path: String,
        query: [URLQueryItem],
        body: Data? = nil
    ) async throws -> Data {
        let url = try buildURL(path: path, query: query)
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            req.httpBody = body
            req.setValue("\(body.count)", forHTTPHeaderField: "Content-Length")
        }

        let (data, resp): (Data, URLResponse)
        do {
            (data, resp) = try await session.data(for: req)
        } catch {
            throw NSFileProviderError(.serverUnreachable)
        }
        try validateHTTP(resp)
        return data
    }

    private func validateHTTP(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw NSFileProviderError(.serverUnreachable)
        }
        switch http.statusCode {
        case 200..<300:
            return
        case 404:
            throw NSFileProviderError(.noSuchItem)
        case 409:
            throw NSFileProviderError(.filenameCollision)
        default:
            throw NSFileProviderError(.serverUnreachable)
        }
    }
}

// MARK: - NSFileProviderItem Wrapper

private final class OpenDriveFPItem: NSObject, NSFileProviderItem, NSFileProviderItemDecorating {
    private static let quotaDecorationIdentifier = NSFileProviderItemDecorationIdentifier(
        rawValue: "org.opendrive.mac.fileprovider.Quota"
    )

    let dto: FPBridgeItem

    init(dto: FPBridgeItem) {
        self.dto = dto
    }

    static func identifier(fromStableId stableId: String) -> NSFileProviderItemIdentifier {
        if stableId == "root" {
            return .rootContainer
        }
        return NSFileProviderItemIdentifier(stableId)
    }

    static func stableId(from identifier: NSFileProviderItemIdentifier) -> String {
        if identifier == .rootContainer {
            return "root"
        }
        return identifier.rawValue
    }

    var itemIdentifier: NSFileProviderItemIdentifier {
        Self.identifier(fromStableId: dto.id)
    }

    var parentItemIdentifier: NSFileProviderItemIdentifier {
        Self.identifier(fromStableId: dto.parentId)
    }

    var filename: String {
        dto.id == "root" ? "Open Drive" : dto.name
    }

    var contentType: UTType {
        if dto.isFolder || dto.id == "root" {
            return .folder
        }
        let ext = (dto.name as NSString).pathExtension
        if !ext.isEmpty, let inferred = UTType(filenameExtension: ext), !inferred.isDynamic {
            return inferred
        }
        return .data
    }

    var capabilities: NSFileProviderItemCapabilities {
        if dto.id == "root" || dto.id.hasPrefix("acc:") {
            return [.allowsReading, .allowsAddingSubItems, .allowsContentEnumerating]
        }
        if dto.isFolder {
            return [.allowsReading, .allowsAddingSubItems, .allowsContentEnumerating, .allowsRenaming, .allowsReparenting, .allowsDeleting]
        }
        return [.allowsReading, .allowsWriting, .allowsRenaming, .allowsReparenting, .allowsDeleting]
    }

    var documentSize: NSNumber? {
        dto.isFolder ? nil : NSNumber(value: max(0, dto.size))
    }

    var contentModificationDate: Date? {
        Date(timeIntervalSince1970: dto.modifiedTime)
    }

    var creationDate: Date? {
        Date(timeIntervalSince1970: dto.modifiedTime)
    }

    var itemVersion: NSFileProviderItemVersion {
        let contentToken = Data(dto.versionToken.utf8)
        let metadataToken = Data("\(dto.versionToken)|\(dto.quotaLabel ?? "")".utf8)
        return NSFileProviderItemVersion(contentVersion: contentToken, metadataVersion: metadataToken)
    }

    var userInfo: [AnyHashable: Any]? {
        guard (dto.isFolder || dto.id == "root"),
              let quotaLabel = dto.quotaLabel, !quotaLabel.isEmpty else {
            return nil
        }
        return ["quotaLabel": quotaLabel]
    }

    var decorations: [NSFileProviderItemDecorationIdentifier]? {
        guard (dto.isFolder || dto.id == "root"),
              let quotaLabel = dto.quotaLabel, !quotaLabel.isEmpty else {
            return nil
        }
        return [Self.quotaDecorationIdentifier]
    }
}

// MARK: - NSFileProviderEnumerator

private final class OpenDriveFPEnumerator: NSObject, NSFileProviderEnumerator {
    private let containerIdentifier: NSFileProviderItemIdentifier
    private let client: FPBridgeClient

    init(containerIdentifier: NSFileProviderItemIdentifier, client: FPBridgeClient) {
        self.containerIdentifier = containerIdentifier
        self.client = client
    }

    func invalidate() {}

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        let kind = Self.containerKind(for: containerIdentifier)
        if containerIdentifier == .workingSet || containerIdentifier == .trashContainer {
            observer.finishEnumerating(upTo: nil)
            return
        }
        let parentStableId = OpenDriveFPItem.stableId(from: containerIdentifier)
        let bridgeClient = client
        Task {
            do {
                let items = try await bridgeClient.listChildren(parentId: parentStableId)
                let fpItems = items.map { OpenDriveFPItem(dto: $0) }
                fpLogger.debug("enumerateItems container=\(kind, privacy: .public) count=\(fpItems.count)")
                if !fpItems.isEmpty {
                    observer.didEnumerate(fpItems)
                }
                observer.finishEnumerating(upTo: nil)
            } catch {
                let nsErr = error as NSError
                fpLogger.error("enumerateItems failed container=\(kind, privacy: .public) domain=\(nsErr.domain, privacy: .public) code=\(nsErr.code)")
                observer.finishEnumeratingWithError(error)
            }
        }
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        if containerIdentifier == .workingSet || containerIdentifier == .trashContainer {
            observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
            return
        }
        let kind = Self.containerKind(for: containerIdentifier)
        let currentAnchorString = String(data: anchor.rawValue, encoding: .utf8)
        let bridgeClient = client
        Task {
            do {
                let latestAnchor = try await bridgeClient.fetchSyncAnchor()
                if latestAnchor == currentAnchorString {
                    observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
                } else {
                    observer.finishEnumeratingWithError(NSFileProviderError(.syncAnchorExpired))
                }
            } catch {
                let nsErr = error as NSError
                fpLogger.error("enumerateChanges failed container=\(kind, privacy: .public) domain=\(nsErr.domain, privacy: .public) code=\(nsErr.code)")
                observer.finishEnumeratingWithError(error)
            }
        }
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        let bridgeClient = client
        Task {
            let anchor = (try? await bridgeClient.fetchSyncAnchor()) ?? "0"
            completionHandler(NSFileProviderSyncAnchor(Data(anchor.utf8)))
        }
    }

    private static func containerKind(for identifier: NSFileProviderItemIdentifier) -> String {
        if identifier == .rootContainer { return "root" }
        if identifier == .workingSet { return "workingSet" }
        if identifier == .trashContainer { return "trash" }
        return "item"
    }
}

// MARK: - Replicated Extension Principal Class

@objc(OpenDriveFileProviderExtension)
public final class OpenDriveFileProviderExtension: NSObject, NSFileProviderReplicatedExtension {
    private let domain: NSFileProviderDomain
    private let client: FPBridgeClient

    public required init(domain: NSFileProviderDomain) {
        self.domain = domain
        let info = domain.userInfo ?? [:]
        let port = (info["port"] as? NSNumber)?.intValue ?? (info["port"] as? Int) ?? 0
        let token = (info["token"] as? String) ?? ""
        self.client = FPBridgeClient(port: port, token: token)
        super.init()
        fpLogger.log("Extension init port=\(port) hasToken=\(!token.isEmpty)")
    }

    public func invalidate() {
        client.invalidate()
    }

    public func item(
        for identifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        if identifier == .workingSet || identifier == .trashContainer {
            completionHandler(nil, NSFileProviderError(.noSuchItem))
            return progress
        }
        let stableId = OpenDriveFPItem.stableId(from: identifier)
        let bridgeClient = client
        Task {
            do {
                let dto = try await bridgeClient.fetchItem(id: stableId)
                progress.completedUnitCount = 1
                completionHandler(OpenDriveFPItem(dto: dto), nil)
            } catch {
                let nsErr = error as NSError
                fpLogger.error("item lookup failed domain=\(nsErr.domain, privacy: .public) code=\(nsErr.code)")
                completionHandler(nil, error)
            }
        }
        return progress
    }

    public func fetchContents(
        for itemIdentifier: NSFileProviderItemIdentifier,
        version requestedVersion: NSFileProviderItemVersion?,
        request: NSFileProviderRequest,
        completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        let stableId = OpenDriveFPItem.stableId(from: itemIdentifier)
        let bridgeClient = client
        Task {
            do {
                async let itemDTO = bridgeClient.fetchItem(id: stableId)
                async let fileURL = bridgeClient.downloadContent(id: stableId)
                let (dto, url) = try await (itemDTO, fileURL)
                progress.completedUnitCount = 1
                completionHandler(url, OpenDriveFPItem(dto: dto), nil)
            } catch {
                completionHandler(nil, nil, error)
            }
        }
        return progress
    }

    public func createItem(
        basedOn itemTemplate: NSFileProviderItem,
        fields: NSFileProviderItemFields,
        contents url: URL?,
        options: NSFileProviderCreateItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        let parentStableId = OpenDriveFPItem.stableId(from: itemTemplate.parentItemIdentifier)
        let name = itemTemplate.filename
        let isFolder = itemTemplate.contentType == .folder
        let bridgeClient = client

        // Copy contents synchronously before returning because the passed URL may be scoped to this callback turn.
        let stagedContentURL: URL?
        if let url, !isFolder {
            let copyURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("od-fp-up-\(UUID().uuidString)")
            if (try? FileManager.default.copyItem(at: url, to: copyURL)) != nil {
                stagedContentURL = copyURL
            } else {
                stagedContentURL = nil
            }
        } else {
            stagedContentURL = nil
        }

        Task {
            defer {
                if let stagedContentURL {
                    try? FileManager.default.removeItem(at: stagedContentURL)
                }
            }
            do {
                let dto = try await bridgeClient.createItem(
                    parentId: parentStableId,
                    name: name,
                    isFolder: isFolder,
                    contentURL: stagedContentURL
                )
                progress.completedUnitCount = 1
                completionHandler(OpenDriveFPItem(dto: dto), [], false, nil)
            } catch {
                completionHandler(nil, [], false, error)
            }
        }
        return progress
    }

    public func modifyItem(
        _ item: NSFileProviderItem,
        baseVersion version: NSFileProviderItemVersion,
        changedFields: NSFileProviderItemFields,
        contents newContents: URL?,
        options: NSFileProviderModifyItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        let stableId = OpenDriveFPItem.stableId(from: item.itemIdentifier)
        let bridgeClient = client

        if changedFields.contains(.parentItemIdentifier), item.parentItemIdentifier == .trashContainer {
            Task {
                do {
                    try await bridgeClient.deleteItem(id: stableId)
                    progress.completedUnitCount = 1
                    completionHandler(nil, [], false, nil)
                } catch {
                    completionHandler(nil, [], false, error)
                }
            }
            return progress
        }

        let newParentId = changedFields.contains(.parentItemIdentifier)
            ? OpenDriveFPItem.stableId(from: item.parentItemIdentifier)
            : nil
        let newName = changedFields.contains(.filename) ? item.filename : nil

        let stagedContentURL: URL?
        if changedFields.contains(.contents), let newContents {
            let copyURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("od-fp-mod-\(UUID().uuidString)")
            if (try? FileManager.default.copyItem(at: newContents, to: copyURL)) != nil {
                stagedContentURL = copyURL
            } else {
                stagedContentURL = nil
            }
        } else {
            stagedContentURL = nil
        }

        Task {
            defer {
                if let stagedContentURL {
                    try? FileManager.default.removeItem(at: stagedContentURL)
                }
            }
            do {
                let updated = try await bridgeClient.modifyItem(
                    id: stableId,
                    newParentId: newParentId,
                    newName: newName,
                    contentURL: stagedContentURL
                )
                progress.completedUnitCount = 1
                completionHandler(OpenDriveFPItem(dto: updated), [], false, nil)
            } catch {
                completionHandler(nil, [], false, error)
            }
        }
        return progress
    }

    public func deleteItem(
        identifier: NSFileProviderItemIdentifier,
        baseVersion version: NSFileProviderItemVersion,
        options: NSFileProviderDeleteItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        let stableId = OpenDriveFPItem.stableId(from: identifier)
        let bridgeClient = client
        Task {
            do {
                try await bridgeClient.deleteItem(id: stableId)
                progress.completedUnitCount = 1
                completionHandler(nil)
            } catch {
                completionHandler(error)
            }
        }
        return progress
    }

    public func enumerator(
        for containerItemIdentifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest
    ) throws -> NSFileProviderEnumerator {
        OpenDriveFPEnumerator(containerIdentifier: containerItemIdentifier, client: client)
    }
}
