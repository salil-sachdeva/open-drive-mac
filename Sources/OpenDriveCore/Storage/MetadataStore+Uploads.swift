import SQLite3

// MARK: - Uploads (`uploads` table)

extension MetadataStore {
    public func upsertUpload(_ upload: UploadRecord) throws {
        let sql = """
        INSERT INTO uploads (
            id, localPath, parentId, targetDriveId, name, size, mime, state,
            sessionURL, offset, attempts, lastError, retryAt, pausedReason,
            createdAt, baseVersion, encrypt, resultDriveId, resultVersion,
            renamedLate, baseHash, resultHash, cancelRequested
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            localPath = excluded.localPath,
            parentId = excluded.parentId,
            targetDriveId = excluded.targetDriveId,
            name = excluded.name,
            size = excluded.size,
            mime = excluded.mime,
            state = excluded.state,
            sessionURL = excluded.sessionURL,
            offset = excluded.offset,
            attempts = excluded.attempts,
            lastError = excluded.lastError,
            retryAt = excluded.retryAt,
            pausedReason = excluded.pausedReason,
            createdAt = excluded.createdAt,
            baseVersion = excluded.baseVersion,
            encrypt = excluded.encrypt,
            resultDriveId = excluded.resultDriveId,
            resultVersion = excluded.resultVersion,
            renamedLate = excluded.renamedLate,
            baseHash = excluded.baseHash,
            resultHash = excluded.resultHash,
            cancelRequested = excluded.cancelRequested;
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }

        bindText(stmt, index: 1, upload.id)
        bindText(stmt, index: 2, upload.localPath)
        bindText(stmt, index: 3, upload.parentId)
        bindOptionalText(stmt, index: 4, upload.targetDriveId)
        bindText(stmt, index: 5, upload.name)
        sqlite3_bind_int64(stmt, 6, upload.size)
        bindText(stmt, index: 7, upload.mime)
        bindText(stmt, index: 8, upload.state.rawValue)
        bindOptionalText(stmt, index: 9, upload.sessionURL)
        sqlite3_bind_int64(stmt, 10, upload.offset)
        sqlite3_bind_int(stmt, 11, Int32(upload.attempts))
        bindOptionalText(stmt, index: 12, upload.lastError)
        bindOptionalDouble(stmt, index: 13, upload.retryAt)
        bindOptionalText(stmt, index: 14, upload.pausedReason?.rawValue)
        sqlite3_bind_double(stmt, 15, upload.createdAt)
        bindOptionalText(stmt, index: 16, upload.baseVersion)
        sqlite3_bind_int(stmt, 17, upload.encrypt ? 1 : 0)
        bindOptionalText(stmt, index: 18, upload.resultDriveId)
        bindOptionalText(stmt, index: 19, upload.resultVersion)
        sqlite3_bind_int(stmt, 20, upload.renamedLate ? 1 : 0)
        bindOptionalText(stmt, index: 21, upload.baseHash)
        bindOptionalText(stmt, index: 22, upload.resultHash)
        sqlite3_bind_int(stmt, 23, upload.cancelRequested ? 1 : 0)

        try stepDone(stmt)
    }

    public func fetchPendingUploads() throws -> [UploadRecord] {
        let sql = """
        SELECT * FROM uploads
        WHERE state IN ('queued', 'uploading', 'committing', 'paused', 'failed')
        ORDER BY createdAt ASC;
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        var records: [UploadRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            records.append(decodeUpload(stmt))
        }
        return records
    }

    public func fetchUpload(id: String) throws -> UploadRecord? {
        let stmt = try prepare("SELECT * FROM uploads WHERE id = ? LIMIT 1;")
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, index: 1, id)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return decodeUpload(stmt)
    }

    public func requestCancelUpload(id: String) throws {
        let stmt = try prepare("UPDATE uploads SET cancelRequested = 1 WHERE id = ?;")
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, index: 1, id)
        try stepDone(stmt)
    }

    public func deleteUpload(id: String) throws {
        let stmt = try prepare("DELETE FROM uploads WHERE id = ?;")
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, index: 1, id)
        try stepDone(stmt)
    }

    // MARK: - Decoding

    private func decodeUpload(_ stmt: OpaquePointer) -> UploadRecord {
        let stateRaw = columnText(stmt, 7) ?? UploadState.queued.rawValue
        let pauseRaw = columnText(stmt, 13)
        return UploadRecord(
            id: columnText(stmt, 0) ?? "",
            localPath: columnText(stmt, 1) ?? "",
            parentId: columnText(stmt, 2) ?? "",
            targetDriveId: columnText(stmt, 3),
            name: columnText(stmt, 4) ?? "",
            size: sqlite3_column_int64(stmt, 5),
            mime: columnText(stmt, 6) ?? "application/octet-stream",
            state: UploadState(rawValue: stateRaw) ?? .queued,
            sessionURL: columnText(stmt, 8),
            offset: sqlite3_column_int64(stmt, 9),
            attempts: Int(sqlite3_column_int(stmt, 10)),
            lastError: columnText(stmt, 11),
            retryAt: columnOptionalDouble(stmt, 12),
            pausedReason: pauseRaw.flatMap { PauseReason(rawValue: $0) },
            createdAt: sqlite3_column_double(stmt, 14),
            baseVersion: columnText(stmt, 15),
            encrypt: sqlite3_column_int(stmt, 16) != 0,
            resultDriveId: columnText(stmt, 17),
            resultVersion: columnText(stmt, 18),
            renamedLate: sqlite3_column_int(stmt, 19) != 0,
            baseHash: columnText(stmt, 20),
            resultHash: columnText(stmt, 21),
            cancelRequested: sqlite3_column_int(stmt, 22) != 0
        )
    }
}
