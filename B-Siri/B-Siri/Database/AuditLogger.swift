//
//  AuditLogger.swift
//  B-Siri
//
//  Created by Michael Kolanjian on 30/05/2026.
//

import Foundation

/// AuditLogger is a write-only API wrapper for compile-time safety against deleting/modifying logs
public struct AuditLogger {
    private let dbActor = DatabaseActor.shared
    
    public init() {}
    
    public func log(tier: String, toolName: String, arguments: String, matchedPattern: String?, outcome: String, reason: String?) async throws {
        try await dbActor.insertAuditLog(
            tier: tier,
            toolName: toolName,
            arguments: arguments,
            matchedPattern: matchedPattern,
            outcome: outcome,
            reason: reason
        )
    }
}
