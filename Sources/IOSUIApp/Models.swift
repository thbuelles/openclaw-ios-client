import Foundation

struct ChatMessage: Identifiable, Codable {
    let id: UUID
    let role: String
    let text: String
    let createdAt: Date
    let responseTimeMs: Int?
    let imageBase64: String?

    init(
        id: UUID = UUID(),
        role: String,
        text: String,
        createdAt: Date = .now,
        responseTimeMs: Int? = nil,
        imageBase64: String? = nil
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.createdAt = createdAt
        self.responseTimeMs = responseTimeMs
        self.imageBase64 = imageBase64
    }
}

struct ChatRequest: Codable {
    let text: String
    let session: String
    let imageBase64: String?
    let imageMimeType: String?
}

struct ChatResponse: Codable {
    let reply: String
}

struct ServerEvent: Codable, Identifiable {
    let id: String
    let ts: String
    let type: String
    let title: String
    let message: String
    let session: String?
}

struct EventsResponse: Codable {
    let events: [ServerEvent]
}
