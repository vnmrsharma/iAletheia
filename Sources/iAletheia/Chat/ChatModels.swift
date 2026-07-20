import Foundation

struct ChatSession: Identifiable, Equatable, Codable {
    let id: UUID
    var title: String
    var startedAt: Date
    var updatedAt: Date
    var endedAt: Date?
    var messageCount: Int
    var preview: String

    var isActive: Bool { endedAt == nil }

    init(
        id: UUID = UUID(),
        title: String = "New chat",
        startedAt: Date = Date(),
        updatedAt: Date = Date(),
        endedAt: Date? = nil,
        messageCount: Int = 0,
        preview: String = ""
    ) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.endedAt = endedAt
        self.messageCount = messageCount
        self.preview = preview
    }

    static func title(from firstUserMessage: String) -> String {
        let trimmed = firstUserMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 48 { return trimmed.isEmpty ? "New chat" : trimmed }
        return String(trimmed.prefix(45)) + "…"
    }
}

struct StoredChatMessage: Identifiable, Equatable, Codable {
    enum Role: String, Codable {
        case user
        case assistant
    }

    let id: UUID
    let sessionID: UUID
    let role: Role
    let text: String
    let citationsJSON: String?
    let timestamp: Date

    init(
        id: UUID = UUID(),
        sessionID: UUID,
        role: Role,
        text: String,
        citationsJSON: String? = nil,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.sessionID = sessionID
        self.role = role
        self.text = text
        self.citationsJSON = citationsJSON
        self.timestamp = timestamp
    }

    func toChatMessage() -> ChatMessage {
        let citations: [ChatCitation]
        if let citationsJSON,
           let data = citationsJSON.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([ChatCitation].self, from: data) {
            citations = decoded
        } else {
            citations = []
        }
        return ChatMessage(
            id: id,
            role: role == .user ? .user : .assistant,
            text: text,
            citations: citations,
            timestamp: timestamp
        )
    }
}

struct ConversationTurn: Equatable {
    let role: String // "user" | "assistant"
    let content: String
}

enum SessionFollowUp {
    /// Questions that refer to prior chat / on-screen content without restating it.
    static func isFollowUp(_ query: String) -> Bool {
        let lower = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let signals = [
            "this", "that", "it", "these", "those",
            "the code", "the file", "the error", "the bug",
            "any error", "any bugs", "what's wrong", "what is wrong",
            "fix it", "explain it", "review it", "check it",
            "above", "previous", "you said", "you mentioned",
            "same file", "same screen", "continue"
        ]
        if signals.contains(where: { lower.contains($0) }) { return true }
        // Very short follow-ups
        let words = lower.split(separator: " ")
        return words.count <= 6 && (lower.contains("?") || lower.contains("error") || lower.contains("bug"))
    }
}
