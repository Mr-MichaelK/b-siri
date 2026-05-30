//
//  ChatHistoryRecord.swift
//  B-Siri
//
//  Created by Michael Kolanjian on 30/05/2026.
//

import Foundation

public struct ChatHistoryRecord: Codable {
    public let promptId: String
    public let parentContextId: String?
    public let timestamp: Date
    public let semanticSummary: String?
    public let payloadData: Data?
    
    public init(promptId: String, parentContextId: String?, timestamp: Date = Date(), semanticSummary: String?, payloadData: Data?) {
        self.promptId = promptId
        self.parentContextId = parentContextId
        self.timestamp = timestamp
        self.semanticSummary = semanticSummary
        self.payloadData = payloadData
    }
}
