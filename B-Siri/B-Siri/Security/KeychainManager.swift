//
//  KeychainManager.swift
//  B-Siri
//
//  Created by Michael Kolanjian on 26/05/2026.
//

import Foundation
import Security

public enum KeychainError: Error {
    case duplicateItem
    case itemNotFound
    case unexpectedStatus(OSStatus)
    case randomGenerationFailed
}

public struct KeychainManager {
    private static let service = "mk.B-Siri"
    private static let account = "db_encryption_key"
    
    /// Retrieves the database encryption key from macOS Keychain, generating and saving a new one if it doesn't exist.
    nonisolated public static func getOrCreateDatabaseKey() throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var dataTypeRef: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &dataTypeRef)
        
        if status == errSecSuccess {
            if let data = dataTypeRef as? Data {
                return data
            }
        } else if status == errSecItemNotFound {
            // Key does not exist, generate and store it
            let newKey = try generateSecureRandomKey()
            try storeDatabaseKey(newKey)
            return newKey
        }
        
        throw KeychainError.unexpectedStatus(status)
    }
    
    private static func generateSecureRandomKey() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: 32) // 256 bits
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw KeychainError.randomGenerationFailed
        }
        return Data(bytes)
    }
    
    private static func storeDatabaseKey(_ key: Data) throws {
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: key,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}
