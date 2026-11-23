import SQLite3

// MARK: - Accounts (`account` table)

extension MetadataStore {
    public func upsertAccount(_ account: CloudAccount) throws {
        let sql = """
        INSERT INTO account (
            id, displayName, email, rootId, trashId, metaId,
            changesPageToken, encryptionEnabled, rootCreatedAt, wholeDrive, mountRootId
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            displayName = excluded.displayName,
            email = excluded.email,
            rootId = excluded.rootId,
            trashId = excluded.trashId,
            metaId = excluded.metaId,
            changesPageToken = excluded.changesPageToken,
            encryptionEnabled = excluded.encryptionEnabled,
            rootCreatedAt = excluded.rootCreatedAt,
            wholeDrive = excluded.wholeDrive,
            mountRootId = excluded.mountRootId;
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }

        bindText(stmt, index: 1, account.id)
        bindText(stmt, index: 2, account.displayName)
        bindOptionalText(stmt, index: 3, account.email)
        bindOptionalText(stmt, index: 4, account.rootId)
        bindOptionalText(stmt, index: 5, account.trashId)
        bindOptionalText(stmt, index: 6, account.metaId)
        bindOptionalText(stmt, index: 7, account.changesPageToken)
        sqlite3_bind_int(stmt, 8, account.encryptionEnabled ? 1 : 0)
        bindOptionalDouble(stmt, index: 9, account.rootCreatedAt)
        sqlite3_bind_int(stmt, 10, account.wholeDrive ? 1 : 0)
        bindOptionalText(stmt, index: 11, account.mountRootId)

        try stepDone(stmt)
    }

    public func fetchAccount(id: String) throws -> CloudAccount? {
        let sql = """
        SELECT id, displayName, email, rootId, trashId, metaId,
               changesPageToken, encryptionEnabled, rootCreatedAt, wholeDrive, mountRootId
        FROM account WHERE id = ? LIMIT 1;
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, index: 1, id)

        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return CloudAccount(
            id: columnText(stmt, 0) ?? id,
            displayName: columnText(stmt, 1) ?? "Google Drive",
            email: columnText(stmt, 2),
            rootId: columnText(stmt, 3),
            trashId: columnText(stmt, 4),
            metaId: columnText(stmt, 5),
            changesPageToken: columnText(stmt, 6),
            encryptionEnabled: sqlite3_column_int(stmt, 7) != 0,
            rootCreatedAt: columnOptionalDouble(stmt, 8),
            wholeDrive: sqlite3_column_int(stmt, 9) != 0,
            mountRootId: columnText(stmt, 10)
        )
    }
}
