import Foundation
import UIKit

@MainActor
final class ChatAPI: ObservableObject {
    private static let defaultBackend = "http://100.73.55.46:8787"

    @Published var backendURL: String {
        didSet { UserDefaults.standard.set(backendURL.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "backendURL") }
    }

    init() {
        let saved = UserDefaults.standard.string(forKey: "backendURL")?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let saved, saved.contains("127.0.0.1") || saved.contains("localhost") {
            backendURL = Self.defaultBackend
        } else {
            backendURL = saved?.isEmpty == false ? saved! : Self.defaultBackend
        }
    }

    func send(_ text: String, image: UIImage?, sessionKey: String) async throws -> String {
        let base = backendURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: base + "/chat") else {
            throw URLError(.badURL)
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 35

        let imageData = image?.jpegData(compressionQuality: 0.85)
        let payload = ChatRequest(
            text: text,
            session: sessionKey.trimmingCharacters(in: .whitespacesAndNewlines),
            imageBase64: imageData?.base64EncodedString(),
            imageMimeType: imageData == nil ? nil : "image/jpeg"
        )
        req.httpBody = try JSONEncoder().encode(payload)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }

        let parsed = try JSONDecoder().decode(ChatResponse.self, from: data)
        return parsed.reply
    }
}
