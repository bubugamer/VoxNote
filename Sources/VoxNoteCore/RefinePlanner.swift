import Foundation

public struct RefineProgress: Equatable, Sendable {
    public let currentChunk: Int
    public let totalChunks: Int
    public let processedCharacters: Int
    public let totalCharacters: Int

    public init(currentChunk: Int, totalChunks: Int, processedCharacters: Int, totalCharacters: Int) {
        self.currentChunk = currentChunk
        self.totalChunks = totalChunks
        self.processedCharacters = processedCharacters
        self.totalCharacters = totalCharacters
    }

    public var fraction: Double {
        guard totalCharacters > 0 else { return 0 }
        return min(1, max(0, Double(processedCharacters) / Double(totalCharacters)))
    }
}

public struct RefineModelProfile: Equatable, Sendable {
    public let contextTokens: Int
    public let maxOutputTokens: Int
    public let targetInputTokens: Int
    public let hardInputTokens: Int
    public let disablesThinking: Bool

    public static func profile(for model: String, baseURL: String) -> RefineModelProfile {
        let normalizedModel = model.lowercased()
        let normalizedURL = baseURL.lowercased()
        if normalizedURL.contains("deepseek") || normalizedModel.contains("deepseek-v4") {
            return RefineModelProfile(
                contextTokens: 1_000_000,
                maxOutputTokens: 384_000,
                targetInputTokens: 120_000,
                hardInputTokens: 180_000,
                disablesThinking: true
            )
        }

        return RefineModelProfile(
            contextTokens: 32_000,
            maxOutputTokens: 8_000,
            targetInputTokens: 8_000,
            hardInputTokens: 12_000,
            disablesThinking: false
        )
    }
}

public struct RefineChunk: Equatable, Sendable {
    public let text: String
    public let estimatedTokens: Int
    public let characterCount: Int
}

public struct RefinePlan: Equatable, Sendable {
    public let profile: RefineModelProfile
    public let chunks: [RefineChunk]
    public let totalCharacters: Int

    public var totalChunks: Int { chunks.count }
}

public enum RefinePlanner {
    public static func makePlan(text: String, model: String, baseURL: String) -> RefinePlan {
        let profile = RefineModelProfile.profile(for: model, baseURL: baseURL)
        let chunks = splitText(text, profile: profile)
        return RefinePlan(
            profile: profile,
            chunks: chunks,
            totalCharacters: chunks.reduce(0) { $0 + $1.characterCount }
        )
    }

    public static func estimatedTokens(in text: String) -> Int {
        let total = text.unicodeScalars.reduce(0.0) { partial, scalar in
            partial + estimatedTokens(for: scalar)
        }
        return max(1, Int(ceil(total)))
    }

    public static func maxOutputTokens(for chunk: RefineChunk, profile: RefineModelProfile) -> Int {
        let estimatedOutput = Int(ceil(Double(chunk.estimatedTokens) * 1.3)) + 2_000
        return min(profile.maxOutputTokens, max(1_000, estimatedOutput))
    }

    private static func splitText(_ text: String, profile: RefineModelProfile) -> [RefineChunk] {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return [] }

        var chunks: [RefineChunk] = []
        var current = ""
        var currentTokens = 0

        for part in textParts(from: normalized) {
            let partTokens = estimatedTokens(in: part)
            if !current.isEmpty && currentTokens + partTokens > profile.targetInputTokens {
                appendPossiblyHardSplit(current, profile: profile, to: &chunks)
                current = ""
                currentTokens = 0
            }

            current.append(part)
            currentTokens += partTokens

            if currentTokens >= profile.hardInputTokens {
                appendPossiblyHardSplit(current, profile: profile, to: &chunks)
                current = ""
                currentTokens = 0
            }
        }

        appendPossiblyHardSplit(current, profile: profile, to: &chunks)
        return chunks
    }

    private static func textParts(from text: String) -> [String] {
        var parts: [String] = []
        var start = text.startIndex

        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(after: index)
            if text[index] == "\n" {
                parts.append(String(text[start..<next]))
                start = next
            }
            index = next
        }

        if start < text.endIndex {
            parts.append(String(text[start..<text.endIndex]))
        }
        return parts.isEmpty ? [text] : parts
    }

    private static func appendPossiblyHardSplit(
        _ text: String,
        profile: RefineModelProfile,
        to chunks: inout [RefineChunk]
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if estimatedTokens(in: trimmed) <= profile.hardInputTokens {
            appendChunk(trimmed, to: &chunks)
            return
        }

        for split in hardSplit(trimmed, profile: profile) {
            appendChunk(split, to: &chunks)
        }
    }

    private static func hardSplit(_ text: String, profile: RefineModelProfile) -> [String] {
        var chunks: [String] = []
        var current = ""
        var currentTokens = 0
        var lastBoundary: String.Index?

        for character in text {
            current.append(character)
            currentTokens += estimatedTokens(in: String(character))
            if currentTokens >= Int(Double(profile.hardInputTokens) * 0.75),
               isChunkBoundary(character) {
                lastBoundary = current.endIndex
            }

            guard currentTokens >= profile.hardInputTokens else { continue }

            let splitIndex = lastBoundary ?? current.endIndex
            chunks.append(String(current[..<splitIndex]))
            current = String(current[splitIndex...])
            currentTokens = estimatedTokens(in: current)
            lastBoundary = nil
        }

        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            chunks.append(current)
        }
        return chunks
    }

    private static func appendChunk(_ text: String, to chunks: inout [RefineChunk]) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        chunks.append(RefineChunk(
            text: trimmed,
            estimatedTokens: estimatedTokens(in: trimmed),
            characterCount: trimmed.count
        ))
    }

    private static func isChunkBoundary(_ character: Character) -> Bool {
        character == "\n" ||
            character == "." ||
            character == "?" ||
            character == "!" ||
            character == "。" ||
            character == "？" ||
            character == "！" ||
            character == " "
    }

    private static func estimatedTokens(for scalar: Unicode.Scalar) -> Double {
        if isCJK(scalar) {
            return 0.6
        }
        if scalar.isASCII {
            if CharacterSet.alphanumerics.contains(scalar) {
                return 0.3
            }
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                return 0.1
            }
        }
        return 1
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        return (0x4E00...0x9FFF).contains(value) ||
            (0x3400...0x4DBF).contains(value) ||
            (0x20000...0x2A6DF).contains(value) ||
            (0x2A700...0x2B73F).contains(value) ||
            (0x2B740...0x2B81F).contains(value) ||
            (0x2B820...0x2CEAF).contains(value) ||
            (0xF900...0xFAFF).contains(value)
    }
}

public enum RefineStreamParser {
    public static func contentDelta(from line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("data:") else { return nil }

        let payload = trimmed
            .dropFirst("data:".count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard payload != "[DONE]", let data = payload.data(using: .utf8) else { return nil }

        return try? JSONDecoder().decode(ChatStreamResponse.self, from: data)
            .choices
            .first?
            .delta
            .content
    }
}

struct ChatStreamResponse: Decodable {
    let choices: [ChatStreamChoice]
}

struct ChatStreamChoice: Decodable {
    let delta: ChatStreamDelta
}

struct ChatStreamDelta: Decodable {
    let content: String?
}
