import Foundation
#if canImport(SQLCipher)
import SQLCipher
#else
import SQLite3
#endif

/// A second, query-only SQLite connection with its own serial queue. In WAL mode it reads the
/// last committed state while the writer connection keeps capturing, so UI and search reads
/// never wait behind capture writes, retention deletes or FTS maintenance.
final class DBReadConnection {
    static let cacheSizeKiB = 32_000

    private let queue = DispatchQueue(label: "com.timescroll.db.read", qos: .userInitiated)
    private let queueKey = DispatchSpecificKey<Bool>()
    private let configLock = NSLock()
    private var handle: OpaquePointer?
    // Connection parameters published by the writer once it has opened (and migrated) the DB.
    private var url: URL?
    private var key: Data?
    private var generation = 0
    private var openedGeneration = -1

    init() { queue.setSpecific(key: queueKey, value: true) }

    /// Called by the writer after a successful open; invalidates any open read handle.
    func configure(url: URL, key: Data?) {
        configLock.lock()
        self.url = url
        self.key = key
        generation &+= 1
        configLock.unlock()
    }

    /// Forgets the parameters and closes the read handle (vault lock, storage moves, resets).
    func close() {
        configLock.lock()
        url = nil
        key = nil
        generation &+= 1
        configLock.unlock()
        if DispatchQueue.getSpecific(key: queueKey) == true {
            closeHandle()
        } else {
            queue.sync { closeHandle() }
        }
    }

    var isConfigured: Bool {
        configLock.lock(); defer { configLock.unlock() }
        return url != nil
    }

    func sync<T>(_ block: (OpaquePointer) throws -> T) throws -> T {
        if DispatchQueue.getSpecific(key: queueKey) == true {
            return try block(try openHandleIfNeeded())
        }
        return try queue.sync { try block(try openHandleIfNeeded()) }
    }

    private func openHandleIfNeeded() throws -> OpaquePointer {
        configLock.lock()
        let url = self.url, key = self.key, generation = self.generation
        configLock.unlock()
        if let handle, openedGeneration == generation { return handle }
        closeHandle()
        guard let url else { throw NSError(domain: "TS.DB", code: 700, userInfo: [NSLocalizedDescriptionKey: "Database not open"]) }

        let opened: OpaquePointer = try StoragePaths.withSecurityScope {
            var candidate: OpaquePointer?
            guard sqlite3_open_v2(url.path, &candidate, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let candidate else {
                sqlite3_close(candidate)
                throw NSError(domain: "TS.DB", code: 701, userInfo: [NSLocalizedDescriptionKey: "Read connection open failed"])
            }
            if let key {
                // Must match the writer's SQLCipher settings (see DB.openWithSqlcipher).
                let hex = key.map { String(format: "%02x", $0) }.joined()
                _ = sqlite3_exec(candidate, "PRAGMA key = \"x'\(hex)'\";", nil, nil, nil)
                _ = sqlite3_exec(candidate, "PRAGMA cipher_compatibility = 4;", nil, nil, nil)
                _ = sqlite3_exec(candidate, "PRAGMA kdf_iter = 256000;", nil, nil, nil)
                _ = sqlite3_exec(candidate, "PRAGMA cipher_page_size = 4096;", nil, nil, nil)
                _ = sqlite3_exec(candidate, "PRAGMA cipher_hmac_algorithm = HMAC_SHA256;", nil, nil, nil)
                _ = sqlite3_exec(candidate, "PRAGMA cipher_kdf_algorithm = PBKDF2_HMAC_SHA256;", nil, nil, nil)
            }
            _ = sqlite3_exec(candidate, "PRAGMA query_only = 1;", nil, nil, nil)
            _ = sqlite3_exec(candidate, "PRAGMA temp_store = MEMORY;", nil, nil, nil)
            _ = sqlite3_exec(candidate, "PRAGMA cache_size = -\(Self.cacheSizeKiB);", nil, nil, nil)
            guard sqlite3_exec(candidate, "SELECT count(*) FROM sqlite_master;", nil, nil, nil) == SQLITE_OK else {
                sqlite3_close(candidate)
                throw NSError(domain: "TS.DB", code: 702, userInfo: [NSLocalizedDescriptionKey: "Read connection verification failed"])
            }
            return candidate
        }
        handle = opened
        openedGeneration = generation
        return opened
    }

    private func closeHandle() {
        if let handle { sqlite3_close_v2(handle) }
        handle = nil
        openedGeneration = -1
    }
}
