import Foundation
import Network

extension LocalWebDAVServer {
    /// Handles authenticated JSON/binary requests from the sandboxed `OpenDriveFileProvider` extension.
    func handleFileProviderBridgeRequest(
        method: String,
        target: String,
        headers: [String: String],
        body: Data,
        close: Bool,
        connection: NWConnection
    ) async {
        guard Self.constantTimeEquals(headers["authorization"] ?? "", "Bearer \(bridgeAuthToken)") else {
            await sendStatus(401, reason: "Unauthorized", close: close, on: connection)
            return
        }

        guard let components = URLComponents(string: "http://127.0.0.1" + target) else {
            await sendStatus(400, reason: "Bad Request", close: close, on: connection)
            return
        }

        let query = Dictionary(
            (components.queryItems ?? []).map { ($0.name, $0.value ?? "") },
            uniquingKeysWith: { _, latest in latest }
        )
        let route = components.path

        do {
            switch (method, route) {
            case ("GET", "/_od_fp/ping"):
                await sendJSONData(Data("{\"ok\":true}".utf8), status: 200, reason: "OK", close: close, on: connection)

            case ("GET", "/_od_fp/anchor"):
                let anchor = await driveVolume.currentBridgeSyncAnchor()
                try await sendEncodable(["anchor": anchor], status: 200, reason: "OK", close: close, on: connection)

            case ("GET", "/_od_fp/item"):
                guard let id = query["id"], !id.isEmpty else {
                    await sendStatus(400, reason: "Bad Request", close: close, on: connection)
                    return
                }
                let item = try await driveVolume.bridgeItem(forStableId: id)
                try await sendEncodable(item, status: 200, reason: "OK", close: close, on: connection)

            case ("GET", "/_od_fp/children"):
                let parentId = query["parentId"] ?? "root"
                let children = try await driveVolume.listBridgeChildren(parentStableId: parentId)
                try await sendEncodable(children, status: 200, reason: "OK", close: close, on: connection)

            case ("GET", "/_od_fp/content"):
                guard let id = query["id"], !id.isEmpty else {
                    await sendStatus(400, reason: "Bad Request", close: close, on: connection)
                    return
                }
                let meta = try await driveVolume.bridgeItem(forStableId: id)
                guard !meta.isFolder else {
                    await sendStatus(400, reason: "Is A Directory", close: close, on: connection)
                    return
                }
                let totalSize = max(0, meta.size)
                var firstSlice = Data()
                if totalSize > 0 {
                    let firstLen = Int(min(Int64(OpenDrivePaths.defaultChunkSize), totalSize))
                    firstSlice = try await driveVolume.readBridgeSlice(stableId: id, offset: 0, length: firstLen)
                }

                let headerLines = [
                    "HTTP/1.1 200 OK",
                    "Content-Type: application/octet-stream",
                    "Content-Length: \(totalSize)",
                    "Connection: \(close ? "close" : "keep-alive")",
                    "",
                    ""
                ]
                await sendRaw(Data(headerLines.joined(separator: "\r\n").utf8), on: connection)
                if !firstSlice.isEmpty {
                    await sendRaw(firstSlice, on: connection)
                }

                var offset = Int64(firstSlice.count)
                let chunkSize = OpenDrivePaths.defaultChunkSize
                do {
                    while offset < totalSize {
                        let toRead = Int(min(Int64(chunkSize), totalSize - offset))
                        let slice = try await driveVolume.readBridgeSlice(stableId: id, offset: offset, length: toRead)
                        if slice.isEmpty { break }
                        await sendRaw(slice, on: connection)
                        offset += Int64(slice.count)
                    }
                } catch {
                    connection.cancel()
                }

            case ("POST", "/_od_fp/create"):
                let parentId = query["parentId"] ?? "root"
                guard let name = query["name"], !name.isEmpty else {
                    await sendStatus(400, reason: "Bad Request", close: close, on: connection)
                    return
                }
                let isFolder = (query["isFolder"] == "1" || query["isFolder"]?.lowercased() == "true")
                let created = try await driveVolume.createBridgeItem(
                    parentStableId: parentId,
                    name: name,
                    isFolder: isFolder,
                    content: body
                )
                try await sendEncodable(created, status: 201, reason: "Created", close: close, on: connection)

            case ("POST", "/_od_fp/modify"):
                guard let id = query["id"], !id.isEmpty else {
                    await sendStatus(400, reason: "Bad Request", close: close, on: connection)
                    return
                }
                let newParentId = query["parentId"].flatMap { $0.isEmpty ? nil : $0 }
                let newName = query["name"].flatMap { $0.isEmpty ? nil : $0 }
                let hasContent = (query["hasContent"] == "1" || query["hasContent"]?.lowercased() == "true")
                let updated = try await driveVolume.modifyBridgeItem(
                    stableId: id,
                    newParentStableId: newParentId,
                    newName: newName,
                    newContent: hasContent ? body : nil
                )
                try await sendEncodable(updated, status: 200, reason: "OK", close: close, on: connection)

            case ("DELETE", "/_od_fp/item"):
                guard let id = query["id"], !id.isEmpty else {
                    await sendStatus(400, reason: "Bad Request", close: close, on: connection)
                    return
                }
                try await driveVolume.deleteBridgeItem(stableId: id)
                await sendResponse(status: 204, reason: "No Content", close: close, on: connection)

            default:
                await sendStatus(404, reason: "Not Found", close: close, on: connection)
            }
        } catch let posix as POSIXError {
            switch posix.code {
            case .ENOENT:
                await sendStatus(404, reason: "Not Found", close: close, on: connection)
            case .EEXIST:
                await sendStatus(409, reason: "Conflict", close: close, on: connection)
            case .EISDIR, .ENOTDIR, .EPERM, .EACCES:
                await sendStatus(403, reason: "Forbidden", close: close, on: connection)
            default:
                await sendStatus(500, reason: "Internal Server Error", close: close, on: connection)
            }
        } catch {
            await sendStatus(500, reason: "Internal Server Error", close: close, on: connection)
        }
    }

    private func sendEncodable<T: Encodable>(
        _ value: T,
        status: Int,
        reason: String,
        close: Bool,
        on connection: NWConnection
    ) async throws {
        let data = try JSONEncoder().encode(value)
        await sendJSONData(data, status: status, reason: reason, close: close, on: connection)
    }

    private func sendJSONData(
        _ data: Data,
        status: Int,
        reason: String,
        close: Bool,
        on connection: NWConnection
    ) async {
        await sendResponse(
            status: status,
            reason: reason,
            headers: [("Content-Type", "application/json; charset=utf-8")],
            body: data,
            close: close,
            on: connection
        )
    }
}
