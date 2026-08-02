import CSQLite
import Foundation

final class SQLiteDatabase: @unchecked Sendable {
    private var handle: OpaquePointer?
    private let lock = NSRecursiveLock()
    let url: URL

    init(url: URL) throws {
        self.url = url
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        var database: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &database, flags, nil) == SQLITE_OK, let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "Unable to open SQLite database"
            if let database { sqlite3_close(database) }
            throw SearchMyMacError.database(message)
        }
        handle = database
        _ = try query("PRAGMA journal_mode=WAL")
        _ = try query("PRAGMA synchronous=NORMAL")
        _ = try query("PRAGMA foreign_keys=ON")
        _ = try query("PRAGMA busy_timeout=5000")
    }

    deinit {
        if let handle { sqlite3_close(handle) }
    }

    func execute(_ sql: String, bindings: [SQLiteValue] = []) throws {
        try lock.withLock {
            let statement = try prepare(sql)
            defer { sqlite3_finalize(statement) }
            try bind(bindings, to: statement)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw currentError()
            }
        }
    }

    func query(_ sql: String, bindings: [SQLiteValue] = []) throws -> [[String: SQLiteValue]] {
        try lock.withLock {
            let statement = try prepare(sql)
            defer { sqlite3_finalize(statement) }
            try bind(bindings, to: statement)
            var rows: [[String: SQLiteValue]] = []
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { break }
                guard result == SQLITE_ROW else { throw currentError() }
                var row: [String: SQLiteValue] = [:]
                for index in 0..<sqlite3_column_count(statement) {
                    let key = String(cString: sqlite3_column_name(statement, index))
                    switch sqlite3_column_type(statement, index) {
                    case SQLITE_INTEGER:
                        row[key] = .integer(sqlite3_column_int64(statement, index))
                    case SQLITE_FLOAT:
                        row[key] = .real(sqlite3_column_double(statement, index))
                    case SQLITE_TEXT:
                        row[key] = .text(String(cString: sqlite3_column_text(statement, index)))
                    case SQLITE_BLOB:
                        let count = Int(sqlite3_column_bytes(statement, index))
                        if let bytes = sqlite3_column_blob(statement, index) {
                            row[key] = .blob(Data(bytes: bytes, count: count))
                        } else {
                            row[key] = .blob(Data())
                        }
                    default:
                        row[key] = .null
                    }
                }
                rows.append(row)
            }
            return rows
        }
    }

    func transaction<T>(_ operation: () throws -> T) throws -> T {
        try lock.withLock {
            try execute("BEGIN IMMEDIATE")
            do {
                let value = try operation()
                try execute("COMMIT")
                return value
            } catch {
                try? execute("ROLLBACK")
                throw error
            }
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        guard let handle else { throw SearchMyMacError.database("Database is closed") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw currentError()
        }
        return statement
    }

    private func bind(_ values: [SQLiteValue], to statement: OpaquePointer) throws {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case .null:
                result = sqlite3_bind_null(statement, index)
            case .integer(let value):
                result = sqlite3_bind_int64(statement, index, value)
            case .real(let value):
                result = sqlite3_bind_double(statement, index, value)
            case .text(let value):
                result = sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
            case .blob(let data):
                result = data.withUnsafeBytes { bytes in
                    sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), sqliteTransient)
                }
            }
            guard result == SQLITE_OK else { throw currentError() }
        }
    }

    private func currentError() -> SearchMyMacError {
        guard let handle else { return .database("Database is closed") }
        return .database(String(cString: sqlite3_errmsg(handle)))
    }
}

enum SQLiteValue: Sendable, Equatable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)

    var string: String? {
        if case .text(let value) = self { return value }
        return nil
    }

    var int64: Int64? {
        if case .integer(let value) = self { return value }
        return nil
    }

    var double: Double? {
        switch self {
        case .real(let value): value
        case .integer(let value): Double(value)
        default: nil
        }
    }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private extension NSRecursiveLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
