import Foundation
import SQLite3

// MARK: - Items (`items` table)

extension MetadataStore {
    /// Inserts or updates an item and automatically resolves case-insensitive sibling collisions (`shownAs` / `folded`).
    public func upsertItem(_ item: DriveItem) throws {
        var resolved = item
        if let parentId = item.parentId {
            let siblings = try listChildren(parentId: parentId, includeTrashed: false)
                .filter { $0.driveId != item.driveId }
            resolved = Self.disambiguate(item: item, againstSiblings: siblings)
        } else {
            resolved.shownAs = item.name
            resolved.folded = Self.fold(item.name)
        }

        let sql = """
        INSERT INTO items (
            driveId, parentId, name, encName, isFolder, size, mime, md5, version,
            modifiedTime, isEncrypted, pinned, lastOpenedAt, trashedAt,
            folded, shownAs, tampered, appAuthorized
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(driveId) DO UPDATE SET
            parentId = excluded.parentId,
            name = excluded.name,
            encName = excluded.encName,
            isFolder = excluded.isFolder,
            size = excluded.size,
            mime = excluded.mime,
            md5 = excluded.md5,
            version = excluded.version,
            modifiedTime = excluded.modifiedTime,
            isEncrypted = excluded.isEncrypted,
            pinned = excluded.pinned,
            lastOpenedAt = COALESCE(excluded.lastOpenedAt, items.lastOpenedAt),
            trashedAt = excluded.trashedAt,
            folded = excluded.folded,
            shownAs = excluded.shownAs,
            tampered = excluded.tampered,
            appAuthorized = excluded.appAuthorized;
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }

        bindText(stmt, index: 1, resolved.driveId)
        bindOptionalText(stmt, index: 2, resolved.parentId)
        bindText(stmt, index: 3, resolved.name)
        bindOptionalText(stmt, index: 4, resolved.encName)
        sqlite3_bind_int(stmt, 5, resolved.isFolder ? 1 : 0)
        sqlite3_bind_int64(stmt, 6, resolved.size)
        bindText(stmt, index: 7, resolved.mime)
        bindOptionalText(stmt, index: 8, resolved.md5)
        bindOptionalText(stmt, index: 9, resolved.version)
        sqlite3_bind_double(stmt, 10, resolved.modifiedTime)
        sqlite3_bind_int(stmt, 11, resolved.isEncrypted ? 1 : 0)
        sqlite3_bind_int(stmt, 12, resolved.pinned ? 1 : 0)
        bindOptionalDouble(stmt, index: 13, resolved.lastOpenedAt)
        bindOptionalDouble(stmt, index: 14, resolved.trashedAt)
        bindText(stmt, index: 15, resolved.folded)
        bindText(stmt, index: 16, resolved.shownAs)
        sqlite3_bind_int(stmt, 17, resolved.tampered ? 1 : 0)
        sqlite3_bind_int(stmt, 18, resolved.appAuthorized ? 1 : 0)

        try stepDone(stmt)
    }

    public func fetchItem(driveId: String) throws -> DriveItem? {
        let sql = "SELECT * FROM items WHERE driveId = ? LIMIT 1;"
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, index: 1, driveId)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return decodeItem(stmt)
    }

    public func lookupChild(parentId: String, name: String) throws -> DriveItem? {
        let foldedTarget = Self.fold(name)
        let sql = """
        SELECT * FROM items
        WHERE parentId = ? AND folded = ? AND trashedAt IS NULL
        LIMIT 1;
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, index: 1, parentId)
        bindText(stmt, index: 2, foldedTarget)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return decodeItem(stmt)
    }

    public func listChildren(parentId: String, includeTrashed: Bool = false) throws -> [DriveItem] {
        let sql: String
        if includeTrashed {
            sql = "SELECT * FROM items WHERE parentId = ? ORDER BY isFolder DESC, folded ASC;"
        } else {
            sql = "SELECT * FROM items WHERE parentId = ? AND trashedAt IS NULL ORDER BY isFolder DESC, folded ASC;"
        }
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, index: 1, parentId)

        var results: [DriveItem] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append(decodeItem(stmt))
        }
        return results
    }

    public func deleteItem(driveId: String) throws {
        let stmt = try prepare("DELETE FROM items WHERE driveId = ?;")
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, index: 1, driveId)
        try stepDone(stmt)
    }

    public func markOpened(driveId: String, at timestamp: Double = Date().timeIntervalSince1970) throws {
        let stmt = try prepare("UPDATE items SET lastOpenedAt = ? WHERE driveId = ?;")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, timestamp)
        bindText(stmt, index: 2, driveId)
        try stepDone(stmt)
    }

    public func setPinned(driveId: String, pinned: Bool) throws {
        let stmt = try prepare("UPDATE items SET pinned = ? WHERE driveId = ?;")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, pinned ? 1 : 0)
        bindText(stmt, index: 2, driveId)
        try stepDone(stmt)
    }

    /// Name search used by the command palette and the MCP `search_files` tool; returns recent items for an empty query.
    public func searchItems(query: String, limit: Int = 50) throws -> [DriveItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let sql: String
        if trimmed.isEmpty {
            sql = """
            SELECT * FROM items
            WHERE trashedAt IS NULL
            ORDER BY COALESCE(lastOpenedAt, modifiedTime) DESC
            LIMIT ?;
            """
            let stmt = try prepare(sql)
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int(stmt, 1, Int32(limit))
            var items: [DriveItem] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                items.append(decodeItem(stmt))
            }
            return items
        } else {
            sql = """
            SELECT * FROM items
            WHERE trashedAt IS NULL AND name LIKE ? ESCAPE '\\'
            ORDER BY isFolder DESC, COALESCE(lastOpenedAt, modifiedTime) DESC
            LIMIT ?;
            """
            let escaped = trimmed
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%")
                .replacingOccurrences(of: "_", with: "\\_")
            let stmt = try prepare(sql)
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, index: 1, "%\(escaped)%")
            sqlite3_bind_int(stmt, 2, Int32(limit))
            var items: [DriveItem] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                items.append(decodeItem(stmt))
            }
            return items
        }
    }

    // MARK: - Decoding

    private func decodeItem(_ stmt: OpaquePointer) -> DriveItem {
        DriveItem(
            driveId: columnText(stmt, 0) ?? "",
            parentId: columnText(stmt, 1),
            name: columnText(stmt, 2) ?? "",
            encName: columnText(stmt, 3),
            isFolder: sqlite3_column_int(stmt, 4) != 0,
            size: sqlite3_column_int64(stmt, 5),
            mime: columnText(stmt, 6) ?? "application/octet-stream",
            md5: columnText(stmt, 7),
            version: columnText(stmt, 8),
            modifiedTime: sqlite3_column_double(stmt, 9),
            isEncrypted: sqlite3_column_int(stmt, 10) != 0,
            pinned: sqlite3_column_int(stmt, 11) != 0,
            lastOpenedAt: columnOptionalDouble(stmt, 12),
            trashedAt: columnOptionalDouble(stmt, 13),
            folded: columnText(stmt, 14) ?? "",
            shownAs: columnText(stmt, 15) ?? "",
            tampered: sqlite3_column_int(stmt, 16) != 0,
            appAuthorized: sqlite3_column_int(stmt, 17) != 0
        )
    }
}
