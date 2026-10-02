//
//  SQLiteSupport.swift
//  Advanced Search On Mail
//
//  Petit wrapper autour de SQLite3.
//

import Foundation
import SQLite3

nonisolated(unsafe) let SQLITE_TRANSIENT = unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)

nonisolated struct DBError: Error, LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}

nonisolated enum Bind {
    case text(String)
    case int(Int64)
}

nonisolated extension String {
    /// Minuscules sans accents, pour comparer sans tenir compte de la casse ni des diacritiques.
    var folded: String { folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
}

nonisolated func foldHasImpl(_ ctx: OpaquePointer?, _ argc: Int32, _ argv: UnsafeMutablePointer<OpaquePointer?>?) {
    guard let argv, let a = argv[0], let b = argv[1],
          let ap = sqlite3_value_text(a), let bp = sqlite3_value_text(b) else {
        sqlite3_result_int(ctx, 0)
        return
    }
    let hay = String(cString: ap).folded
    let needle = String(cString: bp)
    sqlite3_result_int(ctx, hay.contains(needle) ? 1 : 0)
}

nonisolated final class SQLite {
    private(set) var handle: OpaquePointer?

    init(path: String, readOnly: Bool) throws {
        let flags = readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        let rc = sqlite3_open_v2(path, &handle, flags, nil)
        guard rc == SQLITE_OK else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "code \(rc)"
            sqlite3_close(handle)
            throw DBError(msg)
        }
        sqlite3_busy_timeout(handle, 5000)
    }

    deinit { sqlite3_close(handle) }

    var lastError: String { String(cString: sqlite3_errmsg(handle)) }

    func registerFoldFunction() {
        sqlite3_create_function_v2(handle, "fold_has", 2, SQLITE_UTF8 | SQLITE_DETERMINISTIC,
                                   nil, foldHasImpl, nil, nil, nil)
    }

    func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(handle, sql, nil, nil, &err) != SQLITE_OK {
            let m = err.map { String(cString: $0) } ?? lastError
            sqlite3_free(err)
            throw DBError(m)
        }
    }

    func query(_ sql: String, _ binds: [Bind] = [], row: (OpaquePointer) throws -> Void) throws {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &st, nil) == SQLITE_OK else { throw DBError(lastError) }
        defer { sqlite3_finalize(st) }
        for (i, b) in binds.enumerated() {
            let idx = Int32(i + 1)
            switch b {
            case .text(let s): sqlite3_bind_text(st, idx, s, -1, SQLITE_TRANSIENT)
            case .int(let n): sqlite3_bind_int64(st, idx, n)
            }
        }
        while true {
            let rc = sqlite3_step(st)
            if rc == SQLITE_ROW { try row(st!) }
            else if rc == SQLITE_DONE { break }
            else { throw DBError(lastError) }
        }
    }

    func hasTable(_ name: String) -> Bool {
        var found = false
        try? query("SELECT 1 FROM sqlite_master WHERE name = ?", [.text(name)]) { _ in found = true }
        return found
    }

    func hasColumn(_ table: String, _ column: String) -> Bool {
        var found = false
        try? query("PRAGMA table_info(\(table))") { st in
            if SQLite.text(st, 1) == column { found = true }
        }
        return found
    }

    static func text(_ st: OpaquePointer, _ col: Int32) -> String {
        sqlite3_column_text(st, col).map { String(cString: $0) } ?? ""
    }
}
