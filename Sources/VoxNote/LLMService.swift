import Foundation
import VoxNoteCore

final class LLMService: @unchecked Sendable {
    static let shared = LLMService()

    private static let firstTokenTimeoutSeconds: TimeInterval = 90
    private static let idleTimeoutSeconds: TimeInterval = 90
    private static let segmentTimeoutSeconds: TimeInterval = 480
    private static let totalRefineTimeoutSeconds: TimeInterval = 1_200
    private static let nonStreamingTimeoutSeconds: TimeInterval = 90
    private static let nonStreamingTimeoutNanoseconds: UInt64 = 90 * 1_000_000_000
    private static let previousContextLength = 1_000

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

    func refine(
        text: String,
        onProgress: (@Sendable (RefineProgress) async -> Void)? = nil
    ) async throws -> String {
        guard isConfigured else { throw AppError.llmNotConfigured }
        let plan = RefinePlanner.makePlan(text: text, model: model, baseURL: baseURL)
        guard !plan.chunks.isEmpty else { return "" }

        var refined: [String] = []
        var previousContext = ""
        var completedCharacters = 0
        let totalDeadline = Date().addingTimeInterval(Self.totalRefineTimeoutSeconds)

        for (index, chunk) in plan.chunks.enumerated() {
            try Task.checkCancellation()
            try checkDeadline(totalDeadline)

            let segmentDeadline = Date().addingTimeInterval(Self.segmentTimeoutSeconds)
            await onProgress?(RefineProgress(
                currentChunk: index + 1,
                totalChunks: plan.totalChunks,
                processedCharacters: completedCharacters,
                totalCharacters: plan.totalCharacters
            ))

            let prompt = """
            Previous context, if any:
            \(previousContext)

            Transcript to correct:
            \(chunk.text)
            """
            let completedAtChunkStart = completedCharacters
            let counter = RefineCharacterCounter()
            let result = try await streamChat(
                userPrompt: prompt,
                maxTokens: RefinePlanner.maxOutputTokens(for: chunk, profile: plan.profile),
                disablesThinking: plan.profile.disablesThinking,
                segmentDeadline: segmentDeadline,
                totalDeadline: totalDeadline,
                onContent: { delta in
                    let generated = counter.add(delta.count)
                    await onProgress?(RefineProgress(
                        currentChunk: index + 1,
                        totalChunks: plan.totalChunks,
                        processedCharacters: min(
                            plan.totalCharacters,
                            completedAtChunkStart + min(generated, chunk.characterCount)
                        ),
                        totalCharacters: plan.totalCharacters
                    ))
                }
            )
            refined.append(result.trimmingCharacters(in: .whitespacesAndNewlines))
            previousContext = String((refined.last ?? "").suffix(Self.previousContextLength))
            completedCharacters = min(plan.totalCharacters, completedCharacters + chunk.characterCount)
            await onProgress?(RefineProgress(
                currentChunk: index + 1,
                totalChunks: plan.totalChunks,
                processedCharacters: completedCharacters,
                totalCharacters: plan.totalCharacters
            ))
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
        request.timeoutInterval = Self.nonStreamingTimeoutSeconds

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

        let (data, response) = try await data(for: request)
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

    private func streamChat(
        userPrompt: String,
        maxTokens: Int,
        disablesThinking: Bool,
        segmentDeadline: Date,
        totalDeadline: Date,
        onContent: @escaping @Sendable (String) async -> Void
    ) async throws -> String {
        guard let url = URL(string: normalizedBaseURL().appending("/chat/completions")) else {
            throw AppError.llmNotConfigured
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = Self.idleTimeoutSeconds

        let payload = StreamingChatRequest(
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
            temperature: 0,
            stream: true,
            maxTokens: maxTokens,
            thinking: disablesThinking ? ThinkingConfig(type: "disabled") : nil
        )
        request.httpBody = try JSONEncoder().encode(payload)

        let activity = RefineActivity()
        return try await withThrowingTaskGroup(of: StreamOutcome.self) { group in
            group.addTask {
                let result = try await self.consumeStream(
                    request: request,
                    activity: activity,
                    segmentDeadline: segmentDeadline,
                    totalDeadline: totalDeadline,
                    onContent: onContent
                )
                return .content(result)
            }
            group.addTask {
                while !Task.isCancelled {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                    if Date() >= segmentDeadline || Date() >= totalDeadline {
                        return .timeout
                    }
                    let timeout = activity.hasContent()
                        ? Self.idleTimeoutSeconds
                        : Self.firstTokenTimeoutSeconds
                    if activity.secondsSinceLastActivity() >= timeout {
                        return .timeout
                    }
                }
                throw CancellationError()
            }

            guard let first = try await group.next() else {
                throw CancellationError()
            }
            group.cancelAll()

            switch first {
            case .content(let content):
                return content
            case .timeout:
                throw AppError.llmTimedOut
            }
        }
    }

    private func consumeStream(
        request: URLRequest,
        activity: RefineActivity,
        segmentDeadline: Date,
        totalDeadline: Date,
        onContent: @escaping @Sendable (String) async -> Void
    ) async throws -> String {
        let (bytes, response) = try await URLSession.shared.bytes(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw AppError.invalidLLMResponse
        }

        if !(200..<300).contains(http.statusCode) {
            var body = ""
            for try await line in bytes.lines {
                body += line
            }
            throw AppError.exportFailed(body.isEmpty ? "HTTP \(http.statusCode)" : body)
        }

        var content = ""
        for try await line in bytes.lines {
            try Task.checkCancellation()
            try checkDeadline(segmentDeadline)
            try checkDeadline(totalDeadline)
            guard let delta = RefineStreamParser.contentDelta(from: line), !delta.isEmpty else {
                continue
            }
            activity.touch()
            content.append(delta)
            await onContent(delta)
        }

        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AppError.invalidLLMResponse
        }
        return trimmed
    }

    private func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let dataTask = Task {
            try await URLSession.shared.data(for: request)
        }
        let timeoutTask = Task {
            do {
                try await Task.sleep(nanoseconds: Self.nonStreamingTimeoutNanoseconds)
                dataTask.cancel()
            } catch {
                // The request finished or was cancelled before the timeout elapsed.
            }
        }

        do {
            return try await withTaskCancellationHandler {
                defer { timeoutTask.cancel() }
                return try await dataTask.value
            } onCancel: {
                dataTask.cancel()
                timeoutTask.cancel()
            }
        } catch is CancellationError {
            if Task.isCancelled {
                throw CancellationError()
            }
            throw AppError.llmTimedOut
        }
    }

    private func checkDeadline(_ deadline: Date) throws {
        if Date() >= deadline {
            throw AppError.llmTimedOut
        }
    }

    private func normalizedBaseURL() -> String {
        let trimmed = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return trimmed.hasSuffix("/v1") ? trimmed : "\(trimmed)/v1"
    }
}

private enum StreamOutcome: Sendable {
    case content(String)
    case timeout
}

private final class RefineActivity: @unchecked Sendable {
    private let lock = NSLock()
    private var lastContent = Date()
    private var receivedContent = false

    func touch() {
        lock.lock()
        lastContent = Date()
        receivedContent = true
        lock.unlock()
    }

    func hasContent() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return receivedContent
    }

    func secondsSinceLastActivity() -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return Date().timeIntervalSince(lastContent)
    }
}

private final class RefineCharacterCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func add(_ delta: Int) -> Int {
        lock.lock()
        value += delta
        let result = value
        lock.unlock()
        return result
    }
}

private struct ChatRequest: Encodable {
    let model: String
    let messages: [ChatMessage]
    let temperature: Double
}

private struct StreamingChatRequest: Encodable {
    let model: String
    let messages: [ChatMessage]
    let temperature: Double
    let stream: Bool
    let maxTokens: Int
    let thinking: ThinkingConfig?

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case temperature
        case stream
        case maxTokens = "max_tokens"
        case thinking
    }
}

private struct ThinkingConfig: Encodable {
    let type: String
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
