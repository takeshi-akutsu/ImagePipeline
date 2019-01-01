import Foundation
import SQLite3

public protocol Storage {
    func store(_ entry: CacheEntry, for url: URL)
    func load(for url: URL) -> CacheEntry?
    func remove(for url: URL)
    func removeAll()
}

public protocol FileProvider {
    var path: String { get }
}

public class SQLiteStorage: Storage {
    private var database: OpaquePointer?
    private var replaceStatement: OpaquePointer?
    private var selectStatement: OpaquePointer?
    private var deleteStatement: OpaquePointer?
    private var deleteAllStatement: OpaquePointer?

    public init(fileProvider: FileProvider = DefaultFileProvider()) {
        let path = fileProvider.path
        do {
            try SQLite.execute { sqlite3_open_v2(path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) }
            try SQLite.execute {
                sqlite3_exec(database,
                             """
                             CREATE TABLE IF NOT EXISTS entry (
                                 id TEXT NOT NULL PRIMARY KEY,
                                 url TEXT NOT NULL,
                                 data BLOB NOT NULL,
                                 mime TEXT,
                                 ttl INTEGER,
                                 created_at INTEGER NOT NULL,
                                 updated_at INTEGER NOT NULL
                             );
                             """,
                             nil,
                             nil,
                             nil) }

            try SQLite.execute {
                sqlite3_prepare_v2(database,
                                   """
                                   REPLACE INTO entry
                                       (id, url, data, mime, ttl, created_at, updated_at)
                                       VALUES
                                       (?,   ?,   ?,    ?,    ?,   ?,          ?);
                                   """,
                                   -1,
                                   &replaceStatement,
                                   nil) }

            try SQLite.execute {
                sqlite3_prepare_v2(database,
                                   """
                                   SELECT * FROM entry WHERE id = ?;
                                   """,
                                   -1,
                                   &selectStatement,
                                   nil) }

            try SQLite.execute {
                sqlite3_prepare_v2(database,
                                   """
                                   DELETE FROM entry WHERE id = ?;
                                   """,
                                   -1,
                                   &deleteStatement,
                                   nil) }

            try SQLite.execute {
                sqlite3_prepare_v2(database,
                                   """
                                   DELETE FROM entry;
                                   """,
                                   -1,
                                   &deleteAllStatement,
                                   nil) }
        } catch {}
    }

    public func store(_ entry: CacheEntry, for url: URL) {
        let statement = replaceStatement
        do {
            try SQLite.execute { sqlite3_bind_text(statement, 1, url.absoluteString.cString(using: .utf8), -1, SQLITE_TRANSIENT) }
            try SQLite.execute { sqlite3_bind_text(statement, 2, entry.url.absoluteString.cString(using: .utf8), -1, SQLITE_TRANSIENT) }
            try SQLite.execute { entry.data.withUnsafeBytes { sqlite3_bind_blob(statement, 3, $0, Int32(entry.data.count), SQLITE_TRANSIENT) } }
            try SQLite.execute { sqlite3_bind_text(statement, 4, entry.contentType, -1, SQLITE_TRANSIENT) }
            if let timeToLive = entry.timeToLive {
                try SQLite.execute { sqlite3_bind_int64(statement, 5, sqlite3_int64(bitPattern: UInt64(timeToLive))) }
            }
            try SQLite.execute { sqlite3_bind_int64(statement, 6, sqlite3_int64(bitPattern: UInt64(entry.creationDate.timeIntervalSince1970))) }
            try SQLite.execute { sqlite3_bind_int64(statement, 7, sqlite3_int64(bitPattern: UInt64(entry.modificationDate.timeIntervalSince1970))) }

            try SQLite.executeUpdate { sqlite3_step(statement) }
            try SQLite.execute { sqlite3_reset(statement) }
        } catch {}
    }

    public func load(for url: URL) -> CacheEntry? {
        let statement = selectStatement
        try? SQLite.execute { sqlite3_bind_text(statement, 1, url.absoluteString.cString(using: .utf8), -1, SQLITE_TRANSIENT) }

        let entry: CacheEntry?
        if sqlite3_step(statement) == SQLITE_ROW {
            guard let text = sqlite3_column_text(statement, 1), let url = URL(string: String(cString: text)) else {
                return nil
            }
            guard let bytes = sqlite3_column_blob(statement, 2) else {
                return nil
            }
            guard let mime = sqlite3_column_text(statement, 3) else {
                return nil
            }
            let ttl = sqlite3_column_int64(statement, 4)
            let createdAt = sqlite3_column_int64(statement, 5)
            let updatedAt = sqlite3_column_int64(statement, 6)

            entry = CacheEntry(url: url,
                               data: Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 2))),
                               contentType: String(cString: mime),
                               timeToLive: TimeInterval(ttl),
                               creationDate: Date(timeIntervalSince1970: TimeInterval(createdAt)),
                               modificationDate: Date(timeIntervalSince1970: TimeInterval(updatedAt)))
        } else {
            entry = nil
        }

        try? SQLite.execute { sqlite3_reset(statement) }

        return entry
    }

    public func remove(for url: URL) {
        let statement = deleteStatement
        do {
            try SQLite.execute { sqlite3_bind_text(statement, 1, url.absoluteString.cString(using: .utf8), -1, SQLITE_TRANSIENT) }
            try SQLite.executeUpdate { sqlite3_step(statement) }
            try SQLite.execute { sqlite3_reset(statement) }
        } catch {}
    }

    public func removeAll() {
        let statement = deleteAllStatement
        do {
            try SQLite.executeUpdate { sqlite3_step(statement) }
            try SQLite.execute { sqlite3_reset(statement) }
        } catch {}
    }

    private enum SQLite {
        static func execute(_ closure: () -> Int32) throws {
            let code = closure()
            if code != SQLITE_OK {
                throw SQLiteError.error(code)
            }
        }

        static func executeUpdate(_ closure: () -> Int32) throws {
            let code = closure()
            if code != SQLITE_DONE {
                throw SQLiteError.error(code)
            }
        }

        private enum SQLiteError: Error {
            case error(Int32)
        }
    }
}

public struct DefaultFileProvider: FileProvider {
    public init() {}

    public var path: String {
        let directory = FileManager().urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return directory.appendingPathComponent("com.folio-sec.cache.sqlite").path
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)
