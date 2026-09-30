// Copyright © 2026 Vadim Zhuk
import Foundation

public struct ChatMessage: Identifiable, Equatable, Codable, Sendable {
    public let id: UUID
    public let role: String
    public let content: String
    
    public init(id: UUID = UUID(), role: String, content: String) {
        self.id = id
        self.role = role
        self.content = content
    }
}
