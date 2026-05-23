import Foundation

final class LLMService: @unchecked Sendable {
    static let shared = LLMService()

    private let defaults = UserDefaults.standard

    private init() {}

    var isEnabled: Bool {
        get { defaults.bool(forKey: "llmEnabled") }
        set {
            defaults.set(newValue, forKey: "llmEnabled")
            NotificationCenter.default.post(name: .settingsDidChange, object: self)
        }
    }

    var baseURL: String {
        get { defaults.string(forKey: "llmBaseURL") ?? "" }
        set { defaults.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "llmBaseURL") }
    }

    var apiKey: String {
        get { defaults.string(forKey: "llmAPIKey") ?? "" }
        set { defaults.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "llmAPIKey") }
    }

    var model: String {
        get { defaults.string(forKey: "llmModel") ?? "" }
        set { defaults.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "llmModel") }
    }

    var isConfigured: Bool {
        !baseURL.isEmpty && !apiKey.isEmpty && !model.isEmpty
    }

    func refine(text: String) async throws -> String {
        guard isConfigured else { throw AppError.llmNotConfigured }
        let chunks = splitText(text, maxLength: 2_000)
        var refined: [String] = []
        var previousContext = ""

        for chunk in chunks {
            let prompt = """
            Previous context, if any:
            \(previousContext)

            Transcript to correct:
            \(chunk)
            """
            let result = try await sendChat(userPrompt: prompt)
            refined.append(result.trimmingCharacters(in: .whitespacesAndNewlines))
            previousContext = String((refined.last ?? "").suffix(200))
        }

        return refined.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func testConnection() async throws -> String {
        guard isConfigured else { throw AppError.llmNotConfigured }
        return try await sendChat(userPrompt: "Reply with exactly: OK")
    }

    private func sendChat(userPrompt: String) async throws -> String {
        guard let url = URL(string: normalizedBaseURL().appending("/chat/completions")) else {
            throw AppError.llmNotConfigured
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 60

        let payload = ChatRequest(
            model: model,
            messages: [
                ChatMessage(role: "system", content: """
                You conservatively correct speech recognition transcripts.
                Preserve every speaker label exactly, including labels like 【Speaker 1】.
                Do not move, rename, remove, or add speaker labels.
                Fix only obvious recognition errors, homophones, punctuation, and technical terms.
                Do not rewrite, summarize, polish, or remove correct content.
                Return only the corrected transcript.
                """),
                ChatMessage(role: "user", content: userPrompt)
            ],
            temperature: 0
        )
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw AppError.exportFailed(body)
        }

        let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        guard let content = decoded.choices.first?.message.content, !content.isEmpty else {
            throw AppError.invalidLLMResponse
        }
        return content
    }

    private func normalizedBaseURL() -> String {
        let trimmed = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return trimmed.hasSuffix("/v1") ? trimmed : "\(trimmed)/v1"
    }

    private func splitText(_ text: String, maxLength: Int) -> [String] {
        guard text.count > maxLength else { return [text] }
        var chunks: [String] = []
        var current = ""

        for scalar in text {
            current.append(scalar)
            let shouldCut = current.count >= maxLength &&
                (scalar == "." || scalar == "?" || scalar == "!" || scalar == "。" || scalar == "？" || scalar == "！" || scalar == "\n")
            if shouldCut {
                chunks.append(current)
                current = ""
            }
        }

        if !current.isEmpty {
            chunks.append(current)
        }
        return chunks
    }
}

private struct ChatRequest: Encodable {
    let model: String
    let messages: [ChatMessage]
    let temperature: Double
}

private struct ChatMessage: Codable {
    let role: String
    let content: String
}

private struct ChatResponse: Decodable {
    let choices: [ChatChoice]
}

private struct ChatChoice: Decodable {
    let message: ChatMessage
}
