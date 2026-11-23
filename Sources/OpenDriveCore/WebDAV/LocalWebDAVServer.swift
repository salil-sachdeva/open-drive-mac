import CryptoKit
import Foundation
import Network
import Security

/// Loopback RFC 4918 Class 2 WebDAV server backed by `DriveVolume`.
/// Bound strictly to `127.0.0.1` so macOS `/sbin/mount_webdav` mounts `~/Library/Open Drive`
/// without requiring kernel extensions or Apple FSKit provisioning profiles.
public actor LocalWebDAVServer {
    public struct LockEntry: Sendable {
        public let token: String
        public let path: String
        public let owner: String
        public let createdAt: Date
    }

    private struct EphemeralEntry: Sendable {
        var data: Data
        var modifiedAt: Date
    }

    private enum BodyReadError: Error {
        case badRequest
        case payloadTooLarge
    }

    private static let defaultMaxBodyBytes = 128 * 1024 * 1024
    private static let maxConnections = 64
    private static let maxChunkHeaderBytes = 4096
    private static let maxChunkTrailerBytes = 16 * 1024
    private static let maxEphemeralCount = 512
    private static let maxEphemeralTotalBytes = 16 * 1024 * 1024
    private static let maxLockCount = 256
    private static let lockTTLSeconds: TimeInterval = 3600

    let driveVolume: DriveVolume
    public let bridgeOnly: Bool
    public let maxBodyBytes: Int
    public nonisolated let bridgeAuthToken: String
    private var listener: NWListener?
    private var activeConnections: [ObjectIdentifier: NWConnection] = [:]
    private var locksByToken: [String: LockEntry] = [:]
    private var ephemeralFiles: [String: EphemeralEntry] = [:]
    private var isStopped = false

    public private(set) var port: UInt16 = 0

    public var baseURL: URL {
        URL(string: "http://127.0.0.1:\(port)/")!
    }

    public init(
        driveVolume: DriveVolume,
        bridgeOnly: Bool = false,
        maxBodyBytes: Int = 128 * 1024 * 1024,
        bridgeAuthToken: String = LocalWebDAVServer.generateBridgeToken()
    ) {
        self.driveVolume = driveVolume
        self.bridgeOnly = bridgeOnly
        self.maxBodyBytes = max(1, maxBodyBytes)
        self.bridgeAuthToken = bridgeAuthToken
    }

    public static func generateBridgeToken() -> String {
        let key = SymmetricKey(size: .bits256)
        return key.withUnsafeBytes { raw in
            raw.map { String(format: "%02x", $0) }.joined()
        }
    }

    public static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8)
        let b = Array(rhs.utf8)
        let maxLen = max(a.count, b.count)
        var diff: UInt8 = a.count == b.count ? 0 : 1
        for i in 0..<maxLen {
            let lhsByte = i < a.count ? a[i] : 0
            let rhsByte = i < b.count ? b[i] : 0
            diff |= (lhsByte ^ rhsByte)
        }
        return diff == 0
    }

    /// Starts the loopback listener on `127.0.0.1` and returns the bound base URL.
    @discardableResult
    public func start() async throws -> URL {
        if port != 0, listener != nil {
            return baseURL
        }
        isStopped = false

        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        parameters.allowLocalEndpointReuse = true

        let newListener = try NWListener(using: parameters)
        self.listener = newListener

        let boundPort: UInt16 = try await withCheckedThrowingContinuation { continuation in
            final class ResumeBox: @unchecked Sendable {
                let lock = NSLock()
                var resumed = false
            }
            let box = ResumeBox()

            newListener.stateUpdateHandler = { state in
                box.lock.withLock {
                    guard !box.resumed else { return }
                    switch state {
                    case .ready:
                        box.resumed = true
                        let actualPort = newListener.port?.rawValue ?? 0
                        continuation.resume(returning: actualPort)
                    case .failed(let error):
                        box.resumed = true
                        continuation.resume(throwing: error)
                    case .cancelled:
                        box.resumed = true
                        continuation.resume(throwing: CancellationError())
                    default:
                        break
                    }
                }
            }

            newListener.newConnectionHandler = { [weak self] connection in
                Task {
                    await self?.acceptConnection(connection)
                }
            }

            newListener.start(queue: DispatchQueue(label: "org.opendrive.webdav.listener"))
        }

        self.port = boundPort
        return baseURL
    }

    public func stop() {
        isStopped = true
        listener?.cancel()
        listener = nil
        port = 0
        for connection in activeConnections.values {
            connection.cancel()
        }
        activeConnections.removeAll()
        locksByToken.removeAll()
        ephemeralFiles.removeAll()
    }

    // MARK: - Connection Loop

    private func acceptConnection(_ connection: NWConnection) {
        guard !isStopped, activeConnections.count < Self.maxConnections else {
            connection.cancel()
            return
        }
        let connId = ObjectIdentifier(connection)
        activeConnections[connId] = connection

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                Task { await self?.removeConnection(connId) }
            default:
                break
            }
        }
        connection.start(queue: DispatchQueue(label: "org.opendrive.webdav.conn.\(connId.hashValue)"))

        Task { [weak self] in
            await self?.serveConnection(connection, connId: connId)
        }
    }

    private func removeConnection(_ connId: ObjectIdentifier) {
        activeConnections.removeValue(forKey: connId)
    }

    private func serveConnection(_ connection: NWConnection, connId: ObjectIdentifier) async {
        defer {
            connection.cancel()
            activeConnections.removeValue(forKey: connId)
        }

        var buffer = Data()
        let headerSeparator = Data("\r\n\r\n".utf8)

        while !isStopped {
            while buffer.range(of: headerSeparator) == nil {
                guard let chunk = await receiveChunk(from: connection), !chunk.isEmpty else {
                    return
                }
                buffer.append(chunk)
                if buffer.count > 128 * 1024, buffer.range(of: headerSeparator) == nil {
                    await sendStatus(431, reason: "Request Header Fields Too Large", close: true, on: connection)
                    return
                }
            }

            guard let sepRange = buffer.range(of: headerSeparator) else { return }
            let headerData = buffer.subdata(in: buffer.startIndex..<sepRange.lowerBound)
            buffer.removeSubrange(buffer.startIndex..<sepRange.upperBound)

            guard let parsedHeader = Self.parseHTTPHeader(from: headerData) else {
                await sendStatus(400, reason: "Bad Request", close: true, on: connection)
                return
            }

            if !Self.isValidLoopbackHeaders(parsedHeader.headers) {
                await sendStatus(403, reason: "Forbidden", close: true, on: connection)
                return
            }

            if parsedHeader.headers["expect"]?.lowercased() == "100-continue" {
                if let clStr = parsedHeader.headers["content-length"],
                   let cl = Int(clStr.trimmingCharacters(in: .whitespaces)),
                   cl > maxBodyBytes {
                    await sendStatus(413, reason: "Payload Too Large", close: true, on: connection)
                    return
                }
                await sendRaw(Data("HTTP/1.1 100 Continue\r\n\r\n".utf8), on: connection)
            }

            let body: Data
            do {
                body = try await readRequestBody(
                    headers: parsedHeader.headers,
                    buffer: &buffer,
                    connection: connection
                )
            } catch BodyReadError.payloadTooLarge {
                await sendStatus(413, reason: "Payload Too Large", close: true, on: connection)
                return
            } catch {
                await sendStatus(400, reason: "Bad Request", close: true, on: connection)
                return
            }

            let shouldClose = parsedHeader.shouldClose
            let handled = await handleHTTPRequest(
                method: parsedHeader.method,
                target: parsedHeader.target,
                headers: parsedHeader.headers,
                body: body,
                close: shouldClose,
                connection: connection
            )
            if !handled || shouldClose {
                return
            }
        }
    }

    // MARK: - HTTP Framing & Dispatch

    private struct ParsedHTTPHeader: Sendable {
        let method: String
        let target: String
        let headers: [String: String]
        let shouldClose: Bool
    }

    private static func parseHTTPHeader(from data: Data) -> ParsedHTTPHeader? {
        guard let raw = String(data: data, encoding: .utf8) else { return nil }
        let lines = raw.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2 else { return nil }

        let method = String(parts[0]).uppercased()
        let target = String(parts[1])
        let version = parts.count >= 3 ? String(parts[2]).uppercased() : "HTTP/1.1"

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let val = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = val
        }

        let connVal = headers["connection"]?.lowercased() ?? ""
        let shouldClose = connVal.contains("close") || (version == "HTTP/1.0" && !connVal.contains("keep-alive"))
        return ParsedHTTPHeader(method: method, target: target, headers: headers, shouldClose: shouldClose)
    }

    private func readRequestBody(
        headers: [String: String],
        buffer: inout Data,
        connection: NWConnection
    ) async throws -> Data {
        if let te = headers["transfer-encoding"]?.lowercased(), te.contains("chunked") {
            return try await readChunkedBody(buffer: &buffer, connection: connection)
        }
        guard let clStr = headers["content-length"]?.trimmingCharacters(in: .whitespaces), !clStr.isEmpty else {
            return Data()
        }
        guard let contentLength = Int(clStr), contentLength >= 0 else {
            throw BodyReadError.badRequest
        }
        guard contentLength <= maxBodyBytes else {
            throw BodyReadError.payloadTooLarge
        }
        guard contentLength > 0 else {
            return Data()
        }
        while buffer.count < contentLength {
            guard let next = await receiveChunk(from: connection), !next.isEmpty else {
                throw BodyReadError.badRequest
            }
            buffer.append(next)
        }
        let body = buffer.prefix(contentLength)
        buffer.removeFirst(contentLength)
        return Data(body)
    }

    private func readChunkedBody(buffer: inout Data, connection: NWConnection) async throws -> Data {
        var result = Data()
        let crlf = Data("\r\n".utf8)

        while true {
            while buffer.range(of: crlf) == nil {
                if buffer.count > Self.maxChunkHeaderBytes {
                    throw BodyReadError.badRequest
                }
                guard let chunk = await receiveChunk(from: connection), !chunk.isEmpty else {
                    throw BodyReadError.badRequest
                }
                buffer.append(chunk)
            }
            guard let lineRange = buffer.range(of: crlf),
                  lineRange.lowerBound <= Self.maxChunkHeaderBytes else {
                throw BodyReadError.badRequest
            }
            let sizeLineData = buffer.subdata(in: buffer.startIndex..<lineRange.lowerBound)
            buffer.removeSubrange(buffer.startIndex..<lineRange.upperBound)

            let sizeLine = String(data: sizeLineData, encoding: .utf8)?
                .split(separator: ";", maxSplits: 1)
                .first?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard let chunkSize = Int(sizeLine, radix: 16), chunkSize >= 0 else {
                throw BodyReadError.badRequest
            }
            guard chunkSize <= maxBodyBytes, result.count <= maxBodyBytes - chunkSize else {
                throw BodyReadError.payloadTooLarge
            }

            if chunkSize == 0 {
                // Consume trailer headers up to blank line (\r\n)
                var trailerBytes = 0
                while true {
                    if buffer.starts(with: crlf) {
                        buffer.removeFirst(2)
                        break
                    }
                    if let trailerRange = buffer.range(of: crlf) {
                        trailerBytes += trailerRange.upperBound
                        if trailerBytes > Self.maxChunkTrailerBytes {
                            throw BodyReadError.badRequest
                        }
                        buffer.removeSubrange(buffer.startIndex..<trailerRange.upperBound)
                        continue
                    }
                    if buffer.count + trailerBytes > Self.maxChunkTrailerBytes {
                        throw BodyReadError.badRequest
                    }
                    guard let more = await receiveChunk(from: connection), !more.isEmpty else {
                        break
                    }
                    buffer.append(more)
                }
                return result
            }

            let needed = chunkSize + 2
            while buffer.count < needed {
                guard let more = await receiveChunk(from: connection), !more.isEmpty else {
                    throw BodyReadError.badRequest
                }
                buffer.append(more)
            }
            result.append(buffer.prefix(chunkSize))
            buffer.removeFirst(needed)
        }
    }

    private func receiveChunk(from connection: NWConnection) async -> Data? {
        await withCheckedContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 262_144) { data, _, isComplete, error in
                if error != nil {
                    continuation.resume(returning: nil)
                    return
                }
                if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                    return
                }
                if isComplete {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: nil)
            }
        }
    }

    func sendRaw(_ data: Data, on connection: NWConnection) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            connection.send(content: data, completion: .contentProcessed { _ in
                continuation.resume()
            })
        }
    }

    func sendResponse(
        status: Int,
        reason: String,
        headers: [(String, String)] = [],
        body: Data = Data(),
        includeBody: Bool = true,
        close: Bool,
        on connection: NWConnection
    ) async {
        var headerLines = ["HTTP/1.1 \(status) \(reason)"]
        for (k, v) in headers {
            headerLines.append("\(k): \(v)")
        }
        if status != 204 && status != 304 && !headers.contains(where: { $0.0.lowercased() == "content-length" }) {
            headerLines.append("Content-Length: \(body.count)")
        }
        headerLines.append("Connection: \(close ? "close" : "keep-alive")")
        headerLines.append("")
        headerLines.append("")

        var payload = Data(headerLines.joined(separator: "\r\n").utf8)
        if includeBody && !body.isEmpty {
            payload.append(body)
        }
        await sendRaw(payload, on: connection)
    }

    func sendStatus(_ status: Int, reason: String, close: Bool, on connection: NWConnection) async {
        await sendResponse(status: status, reason: reason, close: close, on: connection)
    }

    // MARK: - HTTP / WebDAV Request Handler

    private func handleHTTPRequest(
        method: String,
        target: String,
        headers: [String: String],
        body: Data,
        close: Bool,
        connection: NWConnection
    ) async -> Bool {
        if target == "/_od_fp" || target.hasPrefix("/_od_fp/") || target.hasPrefix("/_od_fp?") {
            await handleFileProviderBridgeRequest(
                method: method,
                target: target,
                headers: headers,
                body: body,
                close: close,
                connection: connection
            )
            return true
        }

        if bridgeOnly {
            await sendStatus(403, reason: "Forbidden", close: close, on: connection)
            return true
        }

        guard let components = Self.parsePathComponents(from: target) else {
            await sendStatus(403, reason: "Forbidden", close: close, on: connection)
            return true
        }

        if Self.isIgnoredSystemNoise(components: components) {
            await sendStatus(404, reason: "Not Found", close: close, on: connection)
            return true
        }

        switch method {
        case "OPTIONS":
            await handleOptions(close: close, connection: connection)

        case "PROPFIND":
            await handlePropfind(components: components, headers: headers, close: close, connection: connection)

        case "PROPPATCH":
            await handleProppatch(components: components, close: close, connection: connection)

        case "LOCK":
            await handleLock(components: components, body: body, close: close, connection: connection)

        case "UNLOCK":
            await handleUnlock(headers: headers, close: close, connection: connection)

        case "HEAD":
            await handleGet(components: components, headers: headers, isHead: true, close: close, connection: connection)

        case "GET":
            await handleGet(components: components, headers: headers, isHead: false, close: close, connection: connection)

        case "PUT":
            await handlePut(components: components, body: body, close: close, connection: connection)

        case "MKCOL":
            await handleMkcol(components: components, body: body, close: close, on: connection)

        case "DELETE":
            await handleDelete(components: components, close: close, connection: connection)

        case "MOVE":
            await handleMove(components: components, headers: headers, close: close, connection: connection)

        case "COPY":
            await handleCopy(components: components, headers: headers, close: close, connection: connection)

        default:
            await sendResponse(
                status: 405,
                reason: "Method Not Allowed",
                headers: [("Allow", Self.allowedMethodsHeader)],
                close: close,
                on: connection
            )
        }
        return true
    }

    // MARK: - Method Implementations

    private static let allowedMethodsHeader = "OPTIONS, GET, HEAD, PUT, DELETE, MKCOL, MOVE, COPY, PROPFIND, PROPPATCH, LOCK, UNLOCK"

    private func handleOptions(close: Bool, connection: NWConnection) async {
        await sendResponse(
            status: 200,
            reason: "OK",
            headers: [
                ("DAV", "1, 2"),
                ("Allow", Self.allowedMethodsHeader),
                ("Accept-Ranges", "bytes"),
                ("MS-Author-Via", "DAV")
            ],
            close: close,
            on: connection
        )
    }

    private func handlePropfind(
        components: [String],
        headers: [String: String],
        close: Bool,
        connection: NWConnection
    ) async {
        let depthHeader = headers["depth"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "1"
        let depth = (depthHeader == "0") ? 0 : 1

        if Self.isEphemeralDotFile(components: components) {
            let key = Self.ephemeralKey(for: components)
            guard let entry = ephemeralFiles[key] else {
                await sendStatus(404, reason: "Not Found", close: close, on: connection)
                return
            }
            let xml = Self.wrapMultiStatusXML([
                Self.filePropResponseXML(
                    href: Self.encodeHref(components: components, isDirectory: false),
                    displayName: components.last ?? "",
                    size: Int64(entry.data.count),
                    modifiedTime: entry.modifiedAt.timeIntervalSince1970,
                    etag: "ephemeral-\(entry.data.count)-\(Int64(entry.modifiedAt.timeIntervalSince1970))",
                    lock: activeLock(for: key)
                )
            ])
            await sendResponse(
                status: 207,
                reason: "Multi-Status",
                headers: [("Content-Type", "application/xml; charset=utf-8")],
                body: Data(xml.utf8),
                close: close,
                on: connection
            )
            return
        }

        guard let targetNode = await resolveNode(at: components) else {
            await sendStatus(404, reason: "Not Found", close: close, on: connection)
            return
        }

        let quota = await driveVolume.aggregatedStorageQuota()
        let availableBytes = quota?.availableBytes ?? 536_870_912_000 // 500 GiB virtual headroom fallback
        let usedBytes = quota?.usedBytes ?? 0

        var responses: [String] = []
        let targetPath = Self.ephemeralKey(for: components)
        if targetNode.isDirectory {
            responses.append(
                Self.directoryPropResponseXML(
                    href: Self.encodeHref(components: components, isDirectory: true),
                    displayName: components.last ?? "Open Drive",
                    modifiedTime: targetNode.modifiedTime,
                    availableBytes: availableBytes,
                    usedBytes: usedBytes,
                    lock: activeLock(for: targetPath)
                )
            )
        } else {
            responses.append(
                Self.filePropResponseXML(
                    href: Self.encodeHref(components: components, isDirectory: false),
                    displayName: targetNode.name,
                    size: targetNode.size,
                    modifiedTime: targetNode.modifiedTime,
                    etag: "\(targetNode.itemId)-\(targetNode.size)-\(Int64(targetNode.modifiedTime * 1000))",
                    lock: activeLock(for: targetPath)
                )
            )
        }

        if depth > 0, targetNode.isDirectory {
            let children = (try? await driveVolume.listDirectory(itemId: targetNode.itemId)) ?? []
            for child in children {
                let childComponents = components + [child.name]
                let childKey = Self.ephemeralKey(for: childComponents)
                if child.isDirectory {
                    responses.append(
                        Self.directoryPropResponseXML(
                            href: Self.encodeHref(components: childComponents, isDirectory: true),
                            displayName: child.name,
                            modifiedTime: child.modifiedTime,
                            availableBytes: availableBytes,
                            usedBytes: usedBytes,
                            lock: activeLock(for: childKey)
                        )
                    )
                } else {
                    responses.append(
                        Self.filePropResponseXML(
                            href: Self.encodeHref(components: childComponents, isDirectory: false),
                            displayName: child.name,
                            size: child.size,
                            modifiedTime: child.modifiedTime,
                            etag: "\(child.itemId)-\(child.size)-\(Int64(child.modifiedTime * 1000))",
                            lock: activeLock(for: childKey)
                        )
                    )
                }
            }

            // Include matching in-memory AppleDouble / Finder sidecars in this directory
            let prefix = components.isEmpty ? "/" : ("/" + components.joined(separator: "/") + "/")
            for (key, entry) in ephemeralFiles where key.hasPrefix(prefix) {
                let remainder = String(key.dropFirst(prefix.count))
                guard !remainder.isEmpty, !remainder.contains("/") else { continue }
                let childComponents = components + [remainder]
                responses.append(
                    Self.filePropResponseXML(
                        href: Self.encodeHref(components: childComponents, isDirectory: false),
                        displayName: remainder,
                        size: Int64(entry.data.count),
                        modifiedTime: entry.modifiedAt.timeIntervalSince1970,
                        etag: "ephemeral-\(entry.data.count)-\(Int64(entry.modifiedAt.timeIntervalSince1970))",
                        lock: activeLock(for: key)
                    )
                )
            }
        }

        let xml = Self.wrapMultiStatusXML(responses)
        await sendResponse(
            status: 207,
            reason: "Multi-Status",
            headers: [("Content-Type", "application/xml; charset=utf-8")],
            body: Data(xml.utf8),
            close: close,
            on: connection
        )
    }

    private func handleProppatch(
        components: [String],
        close: Bool,
        connection: NWConnection
    ) async {
        let isEphemeral = Self.isEphemeralDotFile(components: components)
        if !isEphemeral, await resolveNode(at: components) == nil {
            await sendStatus(404, reason: "Not Found", close: close, on: connection)
            return
        }
        let isDir = isEphemeral ? false : ((await resolveNode(at: components))?.isDirectory ?? false)
        let href = Self.encodeHref(components: components, isDirectory: isDir)
        let xml = Self.wrapMultiStatusXML([
            "<D:response><D:href>\(Self.escapeXML(href))</D:href><D:propstat><D:prop/><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>"
        ])
        await sendResponse(
            status: 207,
            reason: "Multi-Status",
            headers: [("Content-Type", "application/xml; charset=utf-8")],
            body: Data(xml.utf8),
            close: close,
            on: connection
        )
    }

    private func handleLock(
        components: [String],
        body: Data,
        close: Bool,
        connection: NWConnection
    ) async {
        let pathKey = Self.ephemeralKey(for: components)
        pruneLocksIfNeeded()
        let token = "opaquelocktoken:\(UUID().uuidString.lowercased())"
        let owner = Self.extractLockOwner(from: body) ?? "OpenDriveUser"
        let entry = LockEntry(token: token, path: pathKey, owner: owner, createdAt: Date())
        locksByToken[token] = entry

        let lockXML = """
        <?xml version="1.0" encoding="utf-8"?>
        <D:prop xmlns:D="DAV:">
        \(Self.lockDiscoveryInnerXML(for: entry))
        </D:prop>
        """
        await sendResponse(
            status: 200,
            reason: "OK",
            headers: [
                ("Content-Type", "application/xml; charset=utf-8"),
                ("Lock-Token", "<\(token)>")
            ],
            body: Data(lockXML.utf8),
            close: close,
            on: connection
        )
    }

    private func handleUnlock(
        headers: [String: String],
        close: Bool,
        connection: NWConnection
    ) async {
        let rawToken = headers["lock-token"]?.trimmingCharacters(in: CharacterSet(charactersIn: " <>\"")) ?? ""
        if !rawToken.isEmpty {
            locksByToken.removeValue(forKey: rawToken)
        }
        await sendResponse(status: 204, reason: "No Content", close: close, on: connection)
    }

    private func handleGet(
        components: [String],
        headers: [String: String],
        isHead: Bool,
        close: Bool,
        connection: NWConnection
    ) async {
        if Self.isEphemeralDotFile(components: components) {
            let key = Self.ephemeralKey(for: components)
            guard let entry = ephemeralFiles[key] else {
                await sendStatus(404, reason: "Not Found", close: close, on: connection)
                return
            }
            await sendBytePayload(
                totalSize: Int64(entry.data.count),
                modifiedTime: entry.modifiedAt.timeIntervalSince1970,
                etag: "ephemeral-\(entry.data.count)-\(Int64(entry.modifiedAt.timeIntervalSince1970))",
                rangeHeader: headers["range"],
                isHead: isHead,
                close: close,
                connection: connection
            ) { offset, length in
                let start = Int(offset)
                let end = min(entry.data.count, start + length)
                guard start < end else { return Data() }
                return entry.data.subdata(in: start..<end)
            }
            return
        }

        guard let node = await resolveNode(at: components) else {
            await sendStatus(404, reason: "Not Found", close: close, on: connection)
            return
        }
        if node.isDirectory {
            await sendResponse(
                status: 200,
                reason: "OK",
                headers: [("Content-Type", "text/html; charset=utf-8")],
                body: isHead ? Data() : Data("<html><body><h3>\(Self.escapeXML(node.name))</h3></body></html>".utf8),
                includeBody: !isHead,
                close: close,
                on: connection
            )
            return
        }

        let etag = "\(node.itemId)-\(node.size)-\(Int64(node.modifiedTime * 1000))"
        await sendBytePayload(
            totalSize: node.size,
            modifiedTime: node.modifiedTime,
            etag: etag,
            rangeHeader: headers["range"],
            isHead: isHead,
            close: close,
            connection: connection
        ) { offset, length in
            try await self.driveVolume.read(itemId: node.itemId, offset: offset, length: length)
        }
    }

    private func sendBytePayload(
        totalSize: Int64,
        modifiedTime: Double,
        etag: String,
        rangeHeader: String?,
        isHead: Bool,
        close: Bool,
        connection: NWConnection,
        readSlice: @Sendable (Int64, Int) async throws -> Data
    ) async {
        let commonHeaders: [(String, String)] = [
            ("Content-Type", "application/octet-stream"),
            ("Accept-Ranges", "bytes"),
            ("ETag", "\"\(etag)\""),
            ("Last-Modified", Self.rfc1123DateString(from: modifiedTime))
        ]

        let rangeStart: Int64
        let rangeEnd: Int64
        let isPartial: Bool

        if let rangeHeader, !rangeHeader.isEmpty {
            guard totalSize > 0, let parsed = Self.parseByteRange(rangeHeader, totalSize: totalSize) else {
                await sendResponse(
                    status: 416,
                    reason: "Range Not Satisfiable",
                    headers: [("Content-Range", "bytes */\(max(0, totalSize))")],
                    close: close,
                    on: connection
                )
                return
            }
            rangeStart = parsed.lowerBound
            rangeEnd = parsed.upperBound
            isPartial = true
        } else {
            rangeStart = 0
            rangeEnd = max(-1, totalSize - 1)
            isPartial = false
        }

        let responseLength = isPartial ? (rangeEnd - rangeStart + 1) : max(0, totalSize)
        var headers = commonHeaders
        headers.append(("Content-Length", "\(responseLength)"))
        if isPartial {
            headers.append(("Content-Range", "bytes \(rangeStart)-\(rangeEnd)/\(totalSize)"))
        }

        let status = isPartial ? 206 : 200
        let reason = isPartial ? "Partial Content" : "OK"

        var headerLines = ["HTTP/1.1 \(status) \(reason)"]
        for (k, v) in headers {
            headerLines.append("\(k): \(v)")
        }
        headerLines.append("Connection: \(close ? "close" : "keep-alive")")
        headerLines.append("")
        headerLines.append("")
        await sendRaw(Data(headerLines.joined(separator: "\r\n").utf8), on: connection)

        if isHead || responseLength == 0 {
            return
        }

        var cursor = rangeStart
        let limit = rangeStart + responseLength
        let chunkSize = OpenDrivePaths.defaultChunkSize

        do {
            while cursor < limit {
                let toRead = Int(min(Int64(chunkSize), limit - cursor))
                let slice = try await readSlice(cursor, toRead)
                if slice.isEmpty { break }
                await sendRaw(slice, on: connection)
                cursor += Int64(slice.count)
            }
        } catch {
            connection.cancel()
        }
    }

    private func handlePut(
        components: [String],
        body: Data,
        close: Bool,
        connection: NWConnection
    ) async {
        guard let fileName = components.last, !fileName.isEmpty else {
            await sendStatus(403, reason: "Forbidden", close: close, on: connection)
            return
        }

        if Self.isEphemeralDotFile(components: components) {
            guard body.count <= Self.maxEphemeralTotalBytes else {
                await sendStatus(413, reason: "Payload Too Large", close: close, on: connection)
                return
            }
            let key = Self.ephemeralKey(for: components)
            let existed = ephemeralFiles[key] != nil
            storeEphemeralFile(EphemeralEntry(data: body, modifiedAt: Date()), forKey: key)
            if existed {
                await sendStatus(204, reason: "No Content", close: close, on: connection)
            } else {
                await sendStatus(201, reason: "Created", close: close, on: connection)
            }
            return
        }

        // In multi-account mode top-level directories represent accounts; in flattened single-account mode allow root writes.
        let minDepth = await driveVolume.allowsDirectRootMutations() ? 1 : 2
        guard components.count >= minDepth else {
            await sendStatus(403, reason: "Forbidden", close: close, on: connection)
            return
        }

        let parentComponents = Array(components.dropLast())
        guard let parentNode = await resolveNode(at: parentComponents), parentNode.isDirectory else {
            await sendStatus(409, reason: "Conflict", close: close, on: connection)
            return
        }

        do {
            if let existing = try? await driveVolume.lookup(name: fileName, inDirectory: parentNode.itemId) {
                if existing.isDirectory {
                    await sendStatus(405, reason: "Method Not Allowed", close: close, on: connection)
                    return
                }
                _ = try await driveVolume.setAttributes(itemId: existing.itemId, newSize: 0, modifiedTime: Date().timeIntervalSince1970)
                if !body.isEmpty {
                    _ = try await driveVolume.write(itemId: existing.itemId, offset: 0, data: body)
                }
                try await driveVolume.closeAndCommitIfDirty(itemId: existing.itemId)
                DarwinNotifier.shared.post(.changed)
                await sendStatus(204, reason: "No Content", close: close, on: connection)
            } else {
                let created = try await driveVolume.createItem(
                    name: fileName,
                    isDirectory: false,
                    inDirectory: parentNode.itemId
                )
                if !body.isEmpty {
                    _ = try await driveVolume.write(itemId: created.itemId, offset: 0, data: body)
                }
                try await driveVolume.closeAndCommitIfDirty(itemId: created.itemId)
                DarwinNotifier.shared.post(.changed)
                await sendStatus(201, reason: "Created", close: close, on: connection)
            }
        } catch {
            await sendStatus(500, reason: "Internal Server Error", close: close, on: connection)
        }
    }

    private func handleMkcol(
        components: [String],
        body: Data,
        close: Bool,
        on connection: NWConnection
    ) async {
        guard body.isEmpty else {
            await sendStatus(415, reason: "Unsupported Media Type", close: close, on: connection)
            return
        }
        let minDepth = await driveVolume.allowsDirectRootMutations() ? 1 : 2
        guard components.count >= minDepth, let dirName = components.last, !dirName.isEmpty else {
            await sendStatus(403, reason: "Forbidden", close: close, on: connection)
            return
        }
        let parentComponents = Array(components.dropLast())
        guard let parentNode = await resolveNode(at: parentComponents), parentNode.isDirectory else {
            await sendStatus(409, reason: "Conflict", close: close, on: connection)
            return
        }
        if (try? await driveVolume.lookup(name: dirName, inDirectory: parentNode.itemId)) != nil {
            await sendStatus(405, reason: "Method Not Allowed", close: close, on: connection)
            return
        }

        do {
            _ = try await driveVolume.createItem(
                name: dirName,
                isDirectory: true,
                inDirectory: parentNode.itemId
            )
            DarwinNotifier.shared.post(.changed)
            await sendStatus(201, reason: "Created", close: close, on: connection)
        } catch {
            await sendStatus(500, reason: "Internal Server Error", close: close, on: connection)
        }
    }

    private func handleDelete(
        components: [String],
        close: Bool,
        connection: NWConnection
    ) async {
        if Self.isEphemeralDotFile(components: components) {
            let key = Self.ephemeralKey(for: components)
            if ephemeralFiles.removeValue(forKey: key) != nil {
                await sendStatus(204, reason: "No Content", close: close, on: connection)
            } else {
                await sendStatus(404, reason: "Not Found", close: close, on: connection)
            }
            return
        }

        let minDepth = await driveVolume.allowsDirectRootMutations() ? 1 : 2
        guard components.count >= minDepth else {
            await sendStatus(403, reason: "Forbidden", close: close, on: connection)
            return
        }
        guard let targetNode = await resolveNode(at: components) else {
            await sendStatus(404, reason: "Not Found", close: close, on: connection)
            return
        }
        do {
            try await driveVolume.removeItem(itemId: targetNode.itemId)
            DarwinNotifier.shared.post(.changed)
            await sendStatus(204, reason: "No Content", close: close, on: connection)
        } catch {
            await sendStatus(500, reason: "Internal Server Error", close: close, on: connection)
        }
    }

    private func handleMove(
        components: [String],
        headers: [String: String],
        close: Bool,
        connection: NWConnection
    ) async {
        guard let destRaw = headers["destination"],
              let destComponents = Self.parseDestinationComponents(from: destRaw) else {
            await sendStatus(400, reason: "Bad Request", close: close, on: connection)
            return
        }
        let overwrite = (headers["overwrite"]?.uppercased() != "F")

        if Self.isEphemeralDotFile(components: components) || Self.isEphemeralDotFile(components: destComponents) {
            let srcKey = Self.ephemeralKey(for: components)
            let destKey = Self.ephemeralKey(for: destComponents)
            guard let srcEntry = ephemeralFiles[srcKey] else {
                await sendStatus(404, reason: "Not Found", close: close, on: connection)
                return
            }
            let existed = ephemeralFiles[destKey] != nil
            if existed && !overwrite {
                await sendStatus(412, reason: "Precondition Failed", close: close, on: connection)
                return
            }
            ephemeralFiles.removeValue(forKey: srcKey)
            storeEphemeralFile(srcEntry, forKey: destKey)
            await sendStatus(existed ? 204 : 201, reason: existed ? "No Content" : "Created", close: close, on: connection)
            return
        }

        let minDepth = await driveVolume.allowsDirectRootMutations() ? 1 : 2
        guard components.count >= minDepth, destComponents.count >= minDepth,
              let destName = destComponents.last, !destName.isEmpty else {
            await sendStatus(403, reason: "Forbidden", close: close, on: connection)
            return
        }
        guard let srcNode = await resolveNode(at: components) else {
            await sendStatus(404, reason: "Not Found", close: close, on: connection)
            return
        }
        let destParentComponents = Array(destComponents.dropLast())
        guard let destParent = await resolveNode(at: destParentComponents), destParent.isDirectory else {
            await sendStatus(409, reason: "Conflict", close: close, on: connection)
            return
        }

        let existingDest = try? await driveVolume.lookup(name: destName, inDirectory: destParent.itemId)
        if existingDest != nil && !overwrite {
            await sendStatus(412, reason: "Precondition Failed", close: close, on: connection)
            return
        }

        do {
            if let existingDest, existingDest.itemId != srcNode.itemId {
                try await driveVolume.removeItem(itemId: existingDest.itemId)
            }
            _ = try await driveVolume.renameItem(
                itemId: srcNode.itemId,
                toNewName: destName,
                inDestinationDirectory: destParent.itemId
            )
            DarwinNotifier.shared.post(.changed)
            if existingDest != nil {
                await sendStatus(204, reason: "No Content", close: close, on: connection)
            } else {
                await sendStatus(201, reason: "Created", close: close, on: connection)
            }
        } catch let posix as POSIXError where posix.code == .EXDEV {
            await sendStatus(403, reason: "Forbidden", close: close, on: connection)
        } catch {
            await sendStatus(500, reason: "Internal Server Error", close: close, on: connection)
        }
    }

    private func handleCopy(
        components: [String],
        headers: [String: String],
        close: Bool,
        connection: NWConnection
    ) async {
        guard let destRaw = headers["destination"],
              let destComponents = Self.parseDestinationComponents(from: destRaw) else {
            await sendStatus(400, reason: "Bad Request", close: close, on: connection)
            return
        }
        let overwrite = (headers["overwrite"]?.uppercased() != "F")

        let minDepth = await driveVolume.allowsDirectRootMutations() ? 1 : 2
        guard components.count >= minDepth, destComponents.count >= minDepth,
              let destName = destComponents.last, !destName.isEmpty else {
            await sendStatus(403, reason: "Forbidden", close: close, on: connection)
            return
        }
        if destComponents == components || destComponents.starts(with: components) {
            await sendStatus(403, reason: "Forbidden", close: close, on: connection)
            return
        }
        guard let srcNode = await resolveNode(at: components) else {
            await sendStatus(404, reason: "Not Found", close: close, on: connection)
            return
        }
        let destParentComponents = Array(destComponents.dropLast())
        guard let destParent = await resolveNode(at: destParentComponents), destParent.isDirectory else {
            await sendStatus(409, reason: "Conflict", close: close, on: connection)
            return
        }

        let existingDest = try? await driveVolume.lookup(name: destName, inDirectory: destParent.itemId)
        if existingDest != nil && !overwrite {
            await sendStatus(412, reason: "Precondition Failed", close: close, on: connection)
            return
        }

        do {
            if let existingDest, existingDest.itemId != srcNode.itemId {
                try await driveVolume.removeItem(itemId: existingDest.itemId)
            }
            if srcNode.isDirectory {
                try await copyDirectoryRecursively(srcNode, named: destName, intoParentId: destParent.itemId, depth: 0)
            } else {
                try await copyFileNode(srcNode, named: destName, intoParentId: destParent.itemId)
            }
            DarwinNotifier.shared.post(.changed)
            await sendStatus(existingDest != nil ? 204 : 201, reason: existingDest != nil ? "No Content" : "Created", close: close, on: connection)
        } catch {
            await sendStatus(500, reason: "Internal Server Error", close: close, on: connection)
        }
    }

    private func copyFileNode(
        _ srcNode: DriveVolume.VFSNode,
        named destName: String,
        intoParentId parentItemId: UInt64
    ) async throws {
        let created = try await driveVolume.createItem(name: destName, isDirectory: false, inDirectory: parentItemId)
        var offset: Int64 = 0
        let chunkSize = OpenDrivePaths.defaultChunkSize
        while offset < srcNode.size {
            let toRead = Int(min(Int64(chunkSize), srcNode.size - offset))
            let chunk = try await driveVolume.read(itemId: srcNode.itemId, offset: offset, length: toRead)
            if chunk.isEmpty { break }
            _ = try await driveVolume.write(itemId: created.itemId, offset: offset, data: chunk)
            offset += Int64(chunk.count)
        }
        try await driveVolume.closeAndCommitIfDirty(itemId: created.itemId)
    }

    private func copyDirectoryRecursively(
        _ srcDir: DriveVolume.VFSNode,
        named destName: String,
        intoParentId parentItemId: UInt64,
        depth: Int = 0
    ) async throws {
        guard depth < 64 else {
            throw POSIXError(.ELOOP)
        }
        let createdDir = try await driveVolume.createItem(name: destName, isDirectory: true, inDirectory: parentItemId)
        let children = try await driveVolume.listDirectory(itemId: srcDir.itemId)
        for child in children {
            if child.isDirectory {
                try await copyDirectoryRecursively(child, named: child.name, intoParentId: createdDir.itemId, depth: depth + 1)
            } else {
                try await copyFileNode(child, named: child.name, intoParentId: createdDir.itemId)
            }
        }
    }

    // MARK: - Path, Lock, Range & XML Helpers

    private func storeEphemeralFile(_ entry: EphemeralEntry, forKey key: String) {
        ephemeralFiles[key] = entry
        var totalBytes = ephemeralFiles.values.reduce(0) { $0 + $1.data.count }
        if ephemeralFiles.count <= Self.maxEphemeralCount && totalBytes <= Self.maxEphemeralTotalBytes {
            return
        }
        let ordered = ephemeralFiles
            .filter { $0.key != key }
            .sorted { $0.value.modifiedAt < $1.value.modifiedAt }
        for (oldKey, oldEntry) in ordered {
            guard ephemeralFiles.count > Self.maxEphemeralCount || totalBytes > Self.maxEphemeralTotalBytes else {
                break
            }
            ephemeralFiles.removeValue(forKey: oldKey)
            totalBytes -= oldEntry.data.count
        }
    }

    private func pruneLocksIfNeeded() {
        let now = Date()
        locksByToken = locksByToken.filter { now.timeIntervalSince($0.value.createdAt) <= Self.lockTTLSeconds }
        if locksByToken.count >= Self.maxLockCount {
            let overflow = locksByToken.count - Self.maxLockCount + 1
            let oldest = locksByToken.sorted { $0.value.createdAt < $1.value.createdAt }.prefix(overflow)
            for (token, _) in oldest {
                locksByToken.removeValue(forKey: token)
            }
        }
    }

    private static func isValidLoopbackHeaders(_ headers: [String: String]) -> Bool {
        guard let hostHeader = headers["host"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !hostHeader.isEmpty,
              isLoopbackHostString(hostHeader) else {
            return false
        }
        if let origin = headers["origin"]?.trimmingCharacters(in: .whitespacesAndNewlines), !origin.isEmpty {
            guard let originURL = URL(string: origin),
                  let originHost = originURL.host,
                  isLoopbackHostName(originHost) else {
                return false
            }
        }
        return true
    }

    private static func isLoopbackHostString(_ rawHost: String) -> Bool {
        let lower = rawHost.lowercased()
        if lower.hasPrefix("[") {
            guard let closeIdx = lower.firstIndex(of: "]") else { return false }
            let hostOnly = String(lower[...closeIdx])
            let remainder = lower[lower.index(after: closeIdx)...]
            if !remainder.isEmpty {
                guard remainder.hasPrefix(":"), UInt16(remainder.dropFirst()) != nil else { return false }
            }
            return hostOnly == "[::1]"
        }
        let parts = lower.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let hostOnly = String(parts[0])
        if parts.count == 2 {
            guard UInt16(parts[1]) != nil else { return false }
        }
        return hostOnly == "127.0.0.1" || hostOnly == "localhost"
    }

    private static func isLoopbackHostName(_ host: String) -> Bool {
        let lower = host.lowercased()
        return lower == "127.0.0.1" || lower == "localhost" || lower == "::1"
    }

    private func resolveNode(at components: [String]) async -> DriveVolume.VFSNode? {
        var current = await driveVolume.rootNode()
        for part in components {
            guard current.isDirectory,
                  let next = try? await driveVolume.lookup(name: part, inDirectory: current.itemId) else {
                return nil
            }
            current = next
        }
        return current
    }

    private func activeLock(for pathKey: String) -> LockEntry? {
        locksByToken.values.first(where: { $0.path == pathKey })
    }

    private static func parsePathComponents(from target: String) -> [String]? {
        let rawPath: String
        if target.hasPrefix("http://") || target.hasPrefix("https://"),
           let url = URL(string: target) {
            rawPath = url.path
        } else if let q = target.firstIndex(of: "?") {
            rawPath = String(target[..<q])
        } else {
            rawPath = target
        }

        let decoded = rawPath.removingPercentEncoding ?? rawPath
        guard !decoded.contains("\0"), !decoded.contains("\\") else {
            return nil
        }
        let parts = decoded.split(separator: "/").map(String.init)
        if parts.contains("..") {
            return nil
        }
        return parts.filter { !$0.isEmpty && $0 != "." }
    }

    private static func parseDestinationComponents(from headerValue: String) -> [String]? {
        let trimmed = headerValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            guard let url = URL(string: trimmed),
                  let host = url.host,
                  isLoopbackHostName(host) else {
                return nil
            }
        }
        return parsePathComponents(from: trimmed)
    }

    private static func isEphemeralDotFile(components: [String]) -> Bool {
        guard let last = components.last else { return false }
        return last.hasPrefix("._") || last == ".DS_Store" || last == ".localized" || last == ".metadata_never_index"
    }

    private static func isIgnoredSystemNoise(components: [String]) -> Bool {
        let ignored: Set<String> = [".Spotlight-V100", ".fseventsd", ".Trashes", ".TemporaryItems", ".VolumeIcon.icns", ".hidden"]
        return components.contains(where: { ignored.contains($0) })
    }

    private static func ephemeralKey(for components: [String]) -> String {
        "/" + components.joined(separator: "/")
    }

    private static func parseByteRange(_ header: String, totalSize: Int64) -> ClosedRange<Int64>? {
        let trimmed = header.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.hasPrefix("bytes=") else { return nil }
        let spec = String(trimmed.dropFirst(6)).split(separator: ",", maxSplits: 1).first.map(String.init) ?? ""
        let bounds = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard bounds.count == 2 else { return nil }

        if bounds[0].isEmpty {
            // Suffix byte range: bytes=-500
            guard let suffix = Int64(bounds[1]), suffix > 0 else { return nil }
            let start = max(0, totalSize - suffix)
            return start...(totalSize - 1)
        }

        guard let start = Int64(bounds[0]), start >= 0, start < totalSize else { return nil }
        if bounds[1].isEmpty {
            return start...(totalSize - 1)
        }
        guard let reqEnd = Int64(bounds[1]), reqEnd >= start else { return nil }
        return start...min(totalSize - 1, reqEnd)
    }

    private static let urlPathSegmentAllowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))

    private static func encodeHref(components: [String], isDirectory: Bool) -> String {
        if components.isEmpty {
            return "/"
        }
        let encoded = components.map {
            $0.addingPercentEncoding(withAllowedCharacters: urlPathSegmentAllowed) ?? $0
        }.joined(separator: "/")
        return isDirectory ? "/\(encoded)/" : "/\(encoded)"
    }

    private static func wrapMultiStatusXML(_ responses: [String]) -> String {
        """
        <?xml version="1.0" encoding="utf-8"?>
        <D:multistatus xmlns:D="DAV:">
        \(responses.joined(separator: "\n"))
        </D:multistatus>
        """
    }

    private static func directoryPropResponseXML(
        href: String,
        displayName: String,
        modifiedTime: Double,
        availableBytes: UInt64,
        usedBytes: UInt64,
        lock: LockEntry?
    ) -> String {
        let lockXML = lock.map(lockDiscoveryInnerXML(for:)) ?? "<D:lockdiscovery/>"
        return """
        <D:response>
          <D:href>\(escapeXML(href))</D:href>
          <D:propstat>
            <D:prop>
              <D:displayname>\(escapeXML(displayName))</D:displayname>
              <D:resourcetype><D:collection/></D:resourcetype>
              <D:getlastmodified>\(rfc1123DateString(from: modifiedTime))</D:getlastmodified>
              <D:creationdate>\(iso8601DateString(from: modifiedTime))</D:creationdate>
              <D:quota-available-bytes>\(availableBytes)</D:quota-available-bytes>
              <D:quota-used-bytes>\(usedBytes)</D:quota-used-bytes>
              <D:supportedlock><D:lockentry><D:lockscope><D:exclusive/></D:lockscope><D:locktype><D:write/></D:locktype></D:lockentry></D:supportedlock>
              \(lockXML)
            </D:prop>
            <D:status>HTTP/1.1 200 OK</D:status>
          </D:propstat>
        </D:response>
        """
    }

    private static func filePropResponseXML(
        href: String,
        displayName: String,
        size: Int64,
        modifiedTime: Double,
        etag: String,
        lock: LockEntry?
    ) -> String {
        let lockXML = lock.map(lockDiscoveryInnerXML(for:)) ?? "<D:lockdiscovery/>"
        return """
        <D:response>
          <D:href>\(escapeXML(href))</D:href>
          <D:propstat>
            <D:prop>
              <D:displayname>\(escapeXML(displayName))</D:displayname>
              <D:resourcetype/>
              <D:getcontentlength>\(max(0, size))</D:getcontentlength>
              <D:getcontenttype>application/octet-stream</D:getcontenttype>
              <D:getlastmodified>\(rfc1123DateString(from: modifiedTime))</D:getlastmodified>
              <D:creationdate>\(iso8601DateString(from: modifiedTime))</D:creationdate>
              <D:getetag>"\(escapeXML(etag))"</D:getetag>
              <D:supportedlock><D:lockentry><D:lockscope><D:exclusive/></D:lockscope><D:locktype><D:write/></D:locktype></D:lockentry></D:supportedlock>
              \(lockXML)
            </D:prop>
            <D:status>HTTP/1.1 200 OK</D:status>
          </D:propstat>
        </D:response>
        """
    }

    private static func lockDiscoveryInnerXML(for entry: LockEntry) -> String {
        """
        <D:lockdiscovery><D:activelock><D:locktype><D:write/></D:locktype><D:lockscope><D:exclusive/></D:lockscope><D:depth>0</D:depth><D:owner><D:href>\(escapeXML(entry.owner))</D:href></D:owner><D:timeout>Second-3600</D:timeout><D:locktoken><D:href>\(escapeXML(entry.token))</D:href></D:locktoken></D:activelock></D:lockdiscovery>
        """
    }

    private static func extractLockOwner(from body: Data) -> String? {
        guard let text = String(data: body, encoding: .utf8),
              let start = text.range(of: "<D:owner>"),
              let end = text.range(of: "</D:owner>", range: start.upperBound..<text.endIndex) else {
            return nil
        }
        return String(text[start.upperBound..<end.lowerBound])
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func escapeXML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private static func rfc1123DateString(from timestamp: Double) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter.string(from: Date(timeIntervalSince1970: timestamp))
    }

    private static func iso8601DateString(from timestamp: Double) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: Date(timeIntervalSince1970: timestamp))
    }
}
