//
//  DatabaseActor.swift
//  B-Siri
//
//  Created by Michael Kolanjian on 26/05/2026.
//

import Foundation
import SQLCipher

// Bind C function sqlite3_vec_init statically compiled in B-Siri target
@_silgen_name("sqlite3_vec_init")
internal func sqlite3_vec_init(
    _ db: OpaquePointer?,
    _ pzErrMsg: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
    _ pApi: OpaquePointer?
) -> Int32

@globalActor
public actor DatabaseActor {
    public static let shared = DatabaseActor()
    
    private var db: OpaquePointer? = nil
    private let dbPath: URL
    
    public var isVectorReindexing: Bool = false
    
    private static let dbDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()
    
    private init() {
        let fileManager = FileManager.default
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let bSiriDir = appSupport.appendingPathComponent("B-Siri", isDirectory: true)
        
        // Ensure directory exists
        try? fileManager.createDirectory(at: bSiriDir, withIntermediateDirectories: true, attributes: nil)
        
        // Exclude the entire directory recursively from backups
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var mutableDir = bSiriDir
        try? mutableDir.setResourceValues(resourceValues)
        
        self.dbPath = bSiriDir.appendingPathComponent("bsiri.db")
    }
    
    deinit {
        if db != nil {
            sqlite3_close(db)
        }
    }
    
    /// Opens the encrypted SQLCipher SQLite database, registers sqlite-vec, and initializes tables.
    public func openDatabase() throws {
        guard db == nil else { return }
        
        // Get key from Keychain
        let keyData = try KeychainManager.getOrCreateDatabaseKey()
        
        var tempDb: OpaquePointer? = nil
        let openStatus = sqlite3_open(dbPath.path, &tempDb)
        guard openStatus == SQLITE_OK else {
            let errMsg = tempDb.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown open error"
            sqlite3_close(tempDb)
            throw DatabaseError.openFailed(errMsg)
        }
        
        self.db = tempDb
        
        // Authenticate with SQLCipher key
        let keyStatus = keyData.withUnsafeBytes { buffer in
            sqlite3_key(db, buffer.baseAddress, Int32(buffer.count))
        }
        guard keyStatus == SQLITE_OK else {
            sqlite3_close(db)
            db = nil
            throw DatabaseError.keyFailed
        }
        
        // Register sqlite-vec extension
        let vecStatus = sqlite3_vec_init(db, nil, nil)
        guard vecStatus == SQLITE_OK else {
            sqlite3_close(db)
            db = nil
            throw DatabaseError.vecInitFailed
        }
        
        // Verify encryption by executing a test query and enforcing foreign keys
        guard executePRAGMA("PRAGMA foreign_keys = ON;") == SQLITE_OK else {
            sqlite3_close(db)
            db = nil
            throw DatabaseError.authVerificationFailed
        }
        
        // Enable WAL mode
        _ = executePRAGMA("PRAGMA journal_mode = WAL;")
        
        // Create tables
        try createTables()
        
        // Validate embedding dimension
        try validateEmbeddingDimension()
    }
    
    @discardableResult
    private func executePRAGMA(_ sql: String) -> Int32 {
        var stmt: OpaquePointer? = nil
        defer { sqlite3_finalize(stmt) }
        
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return -1
        }
        
        let step = sqlite3_step(stmt)
        return step == SQLITE_ROW || step == SQLITE_DONE ? SQLITE_OK : -1
    }
    
    private func execute(_ sql: String) throws {
        var errMsg: UnsafeMutablePointer<CChar>? = nil
        let status = sqlite3_exec(db, sql, nil, nil, &errMsg)
        if status != SQLITE_OK {
            let errorDescription = errMsg.map { String(cString: $0) } ?? "Unknown error"
            if let errMsg = errMsg {
                sqlite3_free(errMsg)
            }
            throw DatabaseError.executionFailed(sql: sql, error: errorDescription)
        }
    }
    
    private func createTables() throws {
        // 1. chat_history
        try execute("""
        CREATE TABLE IF NOT EXISTS chat_history (
            prompt_id TEXT PRIMARY KEY,
            parent_context_id TEXT NULL,
            timestamp DATETIME DEFAULT CURRENT_TIMESTAMP,
            semantic_summary TEXT,
            payload_data BLOB,
            FOREIGN KEY(parent_context_id) REFERENCES chat_history(prompt_id) ON DELETE CASCADE
        );
        """)
        
        // 2. audit_log
        try execute("""
        CREATE TABLE IF NOT EXISTS audit_log (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp DATETIME DEFAULT CURRENT_TIMESTAMP,
            tier TEXT,
            tool_name TEXT,
            arguments TEXT,
            matched_pattern TEXT,
            outcome TEXT,
            reason TEXT
        );
        """)
        
        // 3. audit_log triggers to enforce append-only immutability at the engine layer
        try execute("""
        CREATE TRIGGER IF NOT EXISTS audit_log_no_update
        BEFORE UPDATE ON audit_log
        BEGIN
            SELECT RAISE(ABORT, 'audit_log table is append-only and cannot be updated');
        END;
        """)
        
        try execute("""
        CREATE TRIGGER IF NOT EXISTS audit_log_no_delete
        BEFORE DELETE ON audit_log
        BEGIN
            SELECT RAISE(ABORT, 'audit_log table is append-only and cannot be deleted');
        END;
        """)
        
        // 4. task_queue_log
        try execute("""
        CREATE TABLE IF NOT EXISTS task_queue_log (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            task_id TEXT,
            step_index INTEGER,
            status TEXT,
            timestamp DATETIME DEFAULT CURRENT_TIMESTAMP
        );
        """)
        
        // 5. db_config
        try execute("""
        CREATE TABLE IF NOT EXISTS db_config (
            key TEXT PRIMARY KEY,
            value TEXT
        );
        """)
    }
    
    private let defaultDimension = 768
    
    private func validateEmbeddingDimension() throws {
        let currentDimension = try fetchConfig(key: "embedding_dimension").flatMap { Int($0) }
        let configuredDimension = defaultDimension
        
        if let dimension = currentDimension {
            if dimension == configuredDimension {
                try createEmbeddingsTable(dimension: dimension)
            } else {
                isVectorReindexing = true
                try dropEmbeddingsTable()
                try createEmbeddingsTable(dimension: configuredDimension)
                try saveConfig(key: "embedding_dimension", value: String(configuredDimension))
                
                Task {
                    await rebuildEmbeddings()
                }
            }
        } else {
            try createEmbeddingsTable(dimension: configuredDimension)
            try saveConfig(key: "embedding_dimension", value: String(configuredDimension))
        }
    }
    
    private func createEmbeddingsTable(dimension: Int) throws {
        try execute("CREATE VIRTUAL TABLE IF NOT EXISTS embeddings USING vec0(prompt_id TEXT, embedding float[\(dimension)]);")
    }
    
    private func dropEmbeddingsTable() throws {
        try execute("DROP TABLE IF EXISTS embeddings;")
    }
    
    private func rebuildEmbeddings() async {
        isVectorReindexing = true
        defer { isVectorReindexing = false }
        
        do {
            let _ = try fetchChatHistoriesWithSummary()
        } catch {
            print("Failed to rebuild embeddings: \(error)")
        }
    }
    
    // MARK: - Configuration Helpers
    
    public func fetchConfig(key: String) throws -> String? {
        let sql = "SELECT value FROM db_config WHERE key = ?;"
        var stmt: OpaquePointer? = nil
        defer { sqlite3_finalize(stmt) }
        
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(sql: sql)
        }
        
        sqlite3_bind_text(stmt, 1, key.cString(using: .utf8), -1, nil)
        
        if sqlite3_step(stmt) == SQLITE_ROW {
            if let cString = sqlite3_column_text(stmt, 0) {
                return String(cString: cString)
            }
        }
        return nil
    }
    
    public func saveConfig(key: String, value: String) throws {
        let sql = "INSERT OR REPLACE INTO db_config (key, value) VALUES (?, ?);"
        var stmt: OpaquePointer? = nil
        defer { sqlite3_finalize(stmt) }
        
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(sql: sql)
        }
        
        sqlite3_bind_text(stmt, 1, key.cString(using: .utf8), -1, nil)
        sqlite3_bind_text(stmt, 2, value.cString(using: .utf8), -1, nil)
        
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DatabaseError.stepFailed(sql: sql)
        }
    }
    
    // MARK: - Chat History CRUD
    
    public func insertChatHistory(record: ChatHistoryRecord) throws {
        let sql = "INSERT INTO chat_history (prompt_id, parent_context_id, semantic_summary, payload_data) VALUES (?, ?, ?, ?);"
        var stmt: OpaquePointer? = nil
        defer { sqlite3_finalize(stmt) }
        
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(sql: sql)
        }
        
        sqlite3_bind_text(stmt, 1, record.promptId.cString(using: .utf8), -1, nil)
        if let parentId = record.parentContextId {
            sqlite3_bind_text(stmt, 2, parentId.cString(using: .utf8), -1, nil)
        } else {
            sqlite3_bind_null(stmt, 2)
        }
        if let summary = record.semanticSummary {
            sqlite3_bind_text(stmt, 3, summary.cString(using: .utf8), -1, nil)
        } else {
            sqlite3_bind_null(stmt, 3)
        }
        if let payload = record.payloadData {
            payload.withUnsafeBytes { buffer in
                sqlite3_bind_blob(stmt, 4, buffer.baseAddress, Int32(buffer.count), nil)
            }
        } else {
            sqlite3_bind_null(stmt, 4)
        }
        
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DatabaseError.stepFailed(sql: sql)
        }
    }
    
    public func fetchChatHistoriesWithSummary() throws -> [ChatHistoryRecord] {
        let sql = "SELECT prompt_id, parent_context_id, timestamp, semantic_summary, payload_data FROM chat_history WHERE semantic_summary IS NOT NULL;"
        var stmt: OpaquePointer? = nil
        defer { sqlite3_finalize(stmt) }
        
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(sql: sql)
        }
        
        var records: [ChatHistoryRecord] = []
        
        while sqlite3_step(stmt) == SQLITE_ROW {
            let promptId = String(cString: sqlite3_column_text(stmt, 0))
            let parentContextId = sqlite3_column_text(stmt, 1).map { String(cString: $0) }
            
            let timestampStr = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
            let timestamp = Self.dbDateFormatter.date(from: timestampStr) ?? Date()
            
            let semanticSummary = sqlite3_column_text(stmt, 3).map { String(cString: $0) }
            
            var payloadData: Data? = nil
            if let blobBytes = sqlite3_column_blob(stmt, 4) {
                let blobSize = sqlite3_column_bytes(stmt, 4)
                payloadData = Data(bytes: blobBytes, count: Int(blobSize))
            }
            
            records.append(ChatHistoryRecord(
                promptId: promptId,
                parentContextId: parentContextId,
                timestamp: timestamp,
                semanticSummary: semanticSummary,
                payloadData: payloadData
            ))
        }
        return records
    }
    
    // MARK: - Embeddings Operations
    
    public func insertEmbedding(promptId: String, vector: [Float]) throws {
        let sql = "INSERT INTO embeddings (prompt_id, embedding) VALUES (?, ?);"
        var stmt: OpaquePointer? = nil
        defer { sqlite3_finalize(stmt) }
        
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(sql: sql)
        }
        
        sqlite3_bind_text(stmt, 1, promptId.cString(using: .utf8), -1, nil)
        
        vector.withUnsafeBufferPointer { buffer in
            sqlite3_bind_blob(stmt, 2, buffer.baseAddress, Int32(vector.count * MemoryLayout<Float>.size), nil)
        }
        
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DatabaseError.stepFailed(sql: sql)
        }
    }
    
    public func vectorSearch(queryVector: [Float], limit: Int) throws -> [(promptId: String, distance: Double)] {
        let sql = "SELECT prompt_id, distance FROM embeddings WHERE embedding MATCH ?1 LIMIT ?2;"
        var stmt: OpaquePointer? = nil
        defer { sqlite3_finalize(stmt) }
        
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(sql: sql)
        }
        
        queryVector.withUnsafeBufferPointer { buffer in
            sqlite3_bind_blob(stmt, 1, buffer.baseAddress, Int32(queryVector.count * MemoryLayout<Float>.size), nil)
        }
        
        sqlite3_bind_int(stmt, 2, Int32(limit))
        
        var results: [(promptId: String, distance: Double)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let promptId = String(cString: sqlite3_column_text(stmt, 0))
            let distance = sqlite3_column_double(stmt, 1)
            results.append((promptId, distance))
        }
        
        return results
    }
    
    // MARK: - Audit Log Writes (Append-Only)
    
    public func insertAuditLog(tier: String, toolName: String, arguments: String, matchedPattern: String?, outcome: String, reason: String?) throws {
        let sql = "INSERT INTO audit_log (tier, tool_name, arguments, matched_pattern, outcome, reason) VALUES (?, ?, ?, ?, ?, ?);"
        var stmt: OpaquePointer? = nil
        defer { sqlite3_finalize(stmt) }
        
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(sql: sql)
        }
        
        sqlite3_bind_text(stmt, 1, tier.cString(using: .utf8), -1, nil)
        sqlite3_bind_text(stmt, 2, toolName.cString(using: .utf8), -1, nil)
        sqlite3_bind_text(stmt, 3, arguments.cString(using: .utf8), -1, nil)
        if let pattern = matchedPattern {
            sqlite3_bind_text(stmt, 4, pattern.cString(using: .utf8), -1, nil)
        } else {
            sqlite3_bind_null(stmt, 4)
        }
        sqlite3_bind_text(stmt, 5, outcome.cString(using: .utf8), -1, nil)
        if let res = reason {
            sqlite3_bind_text(stmt, 6, res.cString(using: .utf8), -1, nil)
        } else {
            sqlite3_bind_null(stmt, 6)
        }
        
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DatabaseError.stepFailed(sql: sql)
        }
    }
    
    // MARK: - Pruning Strategy (Ring Buffer)
    
    public func getDatabaseSize() -> Int64 {
        let fileManager = FileManager.default
        var totalSize: Int64 = 0
        
        if let attrs = try? fileManager.attributesOfItem(atPath: dbPath.path),
           let size = attrs[.size] as? Int64 {
            totalSize += size
        }
        
        let walPath = dbPath.path + "-wal"
        if let attrs = try? fileManager.attributesOfItem(atPath: walPath),
           let size = attrs[.size] as? Int64 {
            totalSize += size
        }
        
        return totalSize
    }
    
    public func pruneOrphanRows() throws {
        let sql = "DELETE FROM chat_history WHERE parent_context_id IS NOT NULL AND parent_context_id NOT IN (SELECT prompt_id FROM chat_history);"
        try execute(sql)
    }
    
    public func pruneOldestThreadsUntilUnderCap() throws {
        let cap: Int64 = 500 * 1024 * 1024 // 500MB
        
        try pruneOrphanRows()
        
        guard getDatabaseSize() > cap else { return }
        
        var rootIds: [String] = []
        let sql = "SELECT prompt_id FROM chat_history WHERE parent_context_id IS NULL ORDER BY timestamp ASC;"
        var stmt: OpaquePointer? = nil
        defer { sqlite3_finalize(stmt) }
        
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                rootIds.append(String(cString: sqlite3_column_text(stmt, 0)))
            }
        }
        
        for rootId in rootIds {
            guard getDatabaseSize() > cap else { break }
            
            if rootIds.count == 1 || rootId == rootIds.last {
                try truncateSingleThreadGroup(cap: cap)
                break
            }
            
            do {
                try execute("BEGIN IMMEDIATE;")
                let deleteSql = "DELETE FROM chat_history WHERE prompt_id = ?;"
                var delStmt: OpaquePointer? = nil
                if sqlite3_prepare_v2(db, deleteSql, -1, &delStmt, nil) == SQLITE_OK {
                    sqlite3_bind_text(delStmt, 1, rootId.cString(using: .utf8), -1, nil)
                    _ = sqlite3_step(delStmt)
                }
                sqlite3_finalize(delStmt)
                try execute("COMMIT;")
            } catch {
                try? execute("ROLLBACK;")
                throw error
            }
        }
        
        try checkpointAndVacuum()
    }
    
    private func truncateSingleThreadGroup(cap: Int64) throws {
        var messageIds: [String] = []
        let sql = "SELECT prompt_id FROM chat_history ORDER BY timestamp ASC;"
        var stmt: OpaquePointer? = nil
        defer { sqlite3_finalize(stmt) }
        
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                messageIds.append(String(cString: sqlite3_column_text(stmt, 0)))
            }
        }
        
        for msgId in messageIds {
            guard getDatabaseSize() > cap else { break }
            
            do {
                try execute("BEGIN IMMEDIATE;")
                let deleteSql = "DELETE FROM chat_history WHERE prompt_id = ?;"
                var delStmt: OpaquePointer? = nil
                if sqlite3_prepare_v2(db, deleteSql, -1, &delStmt, nil) == SQLITE_OK {
                    sqlite3_bind_text(delStmt, 1, msgId.cString(using: .utf8), -1, nil)
                    _ = sqlite3_step(delStmt)
                }
                sqlite3_finalize(delStmt)
                try execute("COMMIT;")
            } catch {
                try? execute("ROLLBACK;")
                throw error
            }
        }
    }
    
    private func checkpointAndVacuum() throws {
        try execute("PRAGMA wal_checkpoint(TRUNCATE);")
        try execute("VACUUM;")
    }
}
