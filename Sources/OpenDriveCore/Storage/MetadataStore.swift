import Foundation
import SQLite3

/// Errors thrown by `MetadataStore`.
public enum MetadataStoreError: Error, LocalizedError {
    case openFailed(String)
    case sqlError(String)
    case invalidState(String)

    public var errorDescription: String? {
        switch self {
        case .openFailed(let msg): return "SQLite open failed: \(msg)"
        case .sqlError(let msg): return "SQLite error: \(msg)"
        case .invalidState(let msg): return "MetadataStore invalid state: \(msg)"
        }
    }
}

/// Thread-safe SQLite (WAL) metadata store backed by six tables:
/// `account`, `items`, `uploads`, `staleNames`, `localChanges`, and `recentFolders`.
public actor MetadataStore {
    public let databaseURL: URL
    nonisolated(unsafe) var db: OpaquePointer?

    // MARK: - Lifecycle

    public init(databaseURL: URL) throws {
        self.databaseURL = databaseURL
        let parentDir = databaseURL.deletingLastPathComponent()
        try OpenDrivePaths.createPrivateDirectory(at: parentDir)

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(databaseURL.path, &handle, flags, nil)
        guard rc == SQLITE_OK, let opened = handle else {
            let msg = handle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "code \(rc)"
            if let handle { sqlite3_close(handle) }
            throw MetadataStoreError.openFailed(msg)
        }
        self.db = opened
        sqlite3_busy_timeout(opened, 5_000)
        try Self.bootstrapSchema(on: opened)
        OpenDrivePaths.setPrivateFilePermissions(at: databaseURL)
    }

    deinit {
        if let db {
            sqlite3_close(db)
        }
    }

    // MARK: - Schema

    private static func bootstrapSchema(on db: OpaquePointer) throws {
        let ddl = """
        PRAGMA journal_mode = WAL;
        PRAGMA synchronous = NORMAL;
        PRAGMA foreign_keys = ON;

        CREATE TABLE IF NOT EXISTS account (
            id TEXT PRIMARY KEY,
            displayName TEXT NOT NULL DEFAULT 'Google Drive',
            email TEXT,
            rootId TEXT,
            trashId TEXT,
            metaId TEXT,
            changesPageToken TEXT,
            encryptionEnabled INTEGER NOT NULL DEFAULT 0,
            rootCreatedAt DOUBLE,
            wholeDrive INTEGER NOT NULL DEFAULT 0,
            mountRootId TEXT
        );

        CREATE TABLE IF NOT EXISTS items (
            driveId TEXT PRIMARY KEY,
            parentId TEXT,
            name TEXT NOT NULL,
            encName TEXT,
            isFolder INTEGER NOT NULL DEFAULT 0,
            size INTEGER NOT NULL DEFAULT 0,
            mime TEXT NOT NULL DEFAULT 'application/octet-stream',
            md5 TEXT,
            version TEXT,
            modifiedTime DOUBLE NOT NULL,
            isEncrypted INTEGER NOT NULL DEFAULT 0,
            pinned INTEGER NOT NULL DEFAULT 0,
            lastOpenedAt DOUBLE,
            trashedAt DOUBLE,
            folded TEXT NOT NULL DEFAULT '',
            shownAs TEXT NOT NULL DEFAULT '',
            tampered INTEGER NOT NULL DEFAULT 0,
            appAuthorized INTEGER NOT NULL DEFAULT 1,
            posixMode INTEGER,
            symlinkTarget TEXT
        );

        CREATE INDEX IF NOT EXISTS items_parent_folded ON items(parentId, folded);

        CREATE TABLE IF NOT EXISTS uploads (
            id TEXT PRIMARY KEY,
            localPath TEXT NOT NULL,
            parentId TEXT NOT NULL,
            targetDriveId TEXT,
            name TEXT NOT NULL,
            size INTEGER NOT NULL,
            mime TEXT NOT NULL,
            state TEXT NOT NULL,
            sessionURL TEXT,
            offset INTEGER NOT NULL DEFAULT 0,
            attempts INTEGER NOT NULL DEFAULT 0,
            lastError TEXT,
            retryAt DOUBLE,
            pausedReason TEXT,
            createdAt DOUBLE NOT NULL,
            baseVersion TEXT,
            encrypt INTEGER NOT NULL DEFAULT 0,
            resultDriveId TEXT,
            resultVersion TEXT,
            renamedLate INTEGER NOT NULL DEFAULT 0,
            baseHash TEXT,
            resultHash TEXT,
            cancelRequested INTEGER NOT NULL DEFAULT 0
        );

        CREATE TABLE IF NOT EXISTS staleNames (
            dir TEXT NOT NULL,
            name TEXT NOT NULL,
            itemId TEXT NOT NULL,
            foundAt DOUBLE NOT NULL,
            releasingAt DOUBLE NOT NULL,
            PRIMARY KEY (dir, name, itemId)
        );

        CREATE TABLE IF NOT EXISTS localChanges (
            driveId TEXT PRIMARY KEY,
            at DOUBLE NOT NULL
        );

        CREATE TABLE IF NOT EXISTS recentFolders (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            usedAt DOUBLE NOT NULL
        );
        """
        var errMsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, ddl, nil, nil, &errMsg)
        if rc != SQLITE_OK {
            let message = errMsg.map { String(cString: $0) } ?? "SQLite DDL error \(rc)"
            if let errMsg { sqlite3_free(errMsg) }
            throw MetadataStoreError.sqlError(message)
        }
        try migrateItemsColumnsIfNeeded(on: db)
    }

    private static func migrateItemsColumnsIfNeeded(on db: OpaquePointer) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(items);", -1, &stmt, nil) == SQLITE_OK,
              let infoStmt = stmt else {
            return
        }
        var existingCols: Set<String> = []
        while sqlite3_step(infoStmt) == SQLITE_ROW {
            if let cStr = sqlite3_column_text(infoStmt, 1) {
                existingCols.insert(String(cString: cStr))
            }
        }
        sqlite3_finalize(infoStmt)

        let migrations: [(String, String)] = [
            ("posixMode", "ALTER TABLE items ADD COLUMN posixMode INTEGER;"),
            ("symlinkTarget", "ALTER TABLE items ADD COLUMN symlinkTarget TEXT;")
        ]
        for (column, alterSQL) in migrations where !existingCols.contains(column) {
            var errMsg: UnsafeMutablePointer<CChar>?
            let rc = sqlite3_exec(db, alterSQL, nil, nil, &errMsg)
            if rc != SQLITE_OK {
                let message = errMsg.map { String(cString: $0) } ?? "SQLite migration error \(rc)"
                if let errMsg { sqlite3_free(errMsg) }
                throw MetadataStoreError.sqlError(message)
            }
        }
    }
}
