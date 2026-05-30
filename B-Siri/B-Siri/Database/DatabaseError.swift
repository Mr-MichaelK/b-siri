//
//  DatabaseError.swift
//  B-Siri
//
//  Created by Michael Kolanjian on 30/05/2026.
//

import Foundation

public enum DatabaseError: Error {
    case openFailed(String)
    case keyFailed
    case vecInitFailed
    case authVerificationFailed
    case prepareFailed(sql: String)
    case stepFailed(sql: String)
    case executionFailed(sql: String, error: String)
}
