import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// MARK: - SQLite Helpers

extension MetadataStore {
    func prepare(_ sql: String) throws -> OpaquePointer {
        guard let db else { throw MetadataStoreError.invalidState("Database closed") }
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let validStmt = stmt else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw MetadataStoreError.sqlError("\(msg) in SQL: \(sql)")
        }
        return validStmt
    }

    func stepDone(_ stmt: OpaquePointer) throws {
        guard let db else { throw MetadataStoreError.invalidState("Database closed") }
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw MetadataStoreError.sqlError(msg)
        }
    }

    func bindText(_ stmt: OpaquePointer, index: Int32, _ value: String) {
        sqlite3_bind_text(stmt, index, value, -1, SQLITE_TRANSIENT)
    }

    func bindOptionalText(_ stmt: OpaquePointer, index: Int32, _ value: String?) {
        if let value {
            sqlite3_bind_text(stmt, index, value, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    func bindOptionalDouble(_ stmt: OpaquePointer, index: Int32, _ value: Double?) {
        if let value {
            sqlite3_bind_double(stmt, index, value)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    func columnText(_ stmt: OpaquePointer, _ col: Int32) -> String? {
        guard sqlite3_column_type(stmt, col) != SQLITE_NULL,
              let cStr = sqlite3_column_text(stmt, col) else {
            return nil
        }
        return String(cString: cStr)
    }

    func columnOptionalDouble(_ stmt: OpaquePointer, _ col: Int32) -> Double? {
        guard sqlite3_column_type(stmt, col) != SQLITE_NULL else { return nil }
        return sqlite3_column_double(stmt, col)
    }
}
