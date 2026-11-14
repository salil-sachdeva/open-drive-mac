import Foundation
import SQLite3

extension MetadataStore {
    // MARK: - Local Changes (`localChanges` table)

    public func recordLocalChange(driveId: String, at timestamp: Double = Date().timeIntervalSince1970) throws {
        let stmt = try prepare("INSERT OR REPLACE INTO localChanges (driveId, at) VALUES (?, ?);")
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, index: 1, driveId)
        sqlite3_bind_double(stmt, 2, timestamp)
        try stepDone(stmt)
    }

    public func localChangeTimestamp(for driveId: String) throws -> Double? {
        let stmt = try prepare("SELECT at FROM localChanges WHERE driveId = ? LIMIT 1;")
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, index: 1, driveId)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return sqlite3_column_double(stmt, 0)
    }

    public func wasRecentlyModifiedLocally(driveId: String, withinSeconds windowSeconds: TimeInterval = 10) throws -> Bool {
        guard let changedAt = try localChangeTimestamp(for: driveId) else { return false }
        return (Date().timeIntervalSince1970 - changedAt) <= windowSeconds
    }

    // MARK: - Recent Folders (`recentFolders` table)

    public func recordRecentFolder(_ folder: RecentFolderRecord) throws {
        let stmt = try prepare("INSERT OR REPLACE INTO recentFolders (id, name, usedAt) VALUES (?, ?, ?);")
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, index: 1, folder.id)
        bindText(stmt, index: 2, folder.name)
        sqlite3_bind_double(stmt, 3, folder.usedAt)
        try stepDone(stmt)
    }

    public func recordRecentFolder(id: String, name: String, usedAt: Double = Date().timeIntervalSince1970) throws {
        try recordRecentFolder(RecentFolderRecord(id: id, name: name, usedAt: usedAt))
    }

    public func listRecentFolders(limit: Int = 10) throws -> [RecentFolderRecord] {
        let stmt = try prepare("SELECT id, name, usedAt FROM recentFolders ORDER BY usedAt DESC LIMIT ?;")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(limit))
        var list: [RecentFolderRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            list.append(
                RecentFolderRecord(
                    id: columnText(stmt, 0) ?? "",
                    name: columnText(stmt, 1) ?? "",
                    usedAt: sqlite3_column_double(stmt, 2)
                )
            )
        }
        return list
    }
}
