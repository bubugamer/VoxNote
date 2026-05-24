import Foundation
import VoxNoteCore

@discardableResult
func check(_ condition: @autoclosure () -> Bool, _ message: String) -> Bool {
    if condition() {
        return true
    }
    fputs("Check failed: \(message)\n", stderr)
    exit(1)
}

let deepSeekTranscript = String(
    repeating: "这是一段中文转录文本，用来验证新的分块策略不会再按两千字切开。\n",
    count: 2_000
)
let deepSeekPlan = RefinePlanner.makePlan(
    text: deepSeekTranscript,
    model: "deepseek-v4-pro",
    baseURL: "https://api.deepseek.com"
)
check(deepSeekPlan.profile.contextTokens == 1_000_000, "DeepSeek context should be 1M tokens")
check(deepSeekPlan.profile.maxOutputTokens == 384_000, "DeepSeek max output should be 384K tokens")
check(deepSeekPlan.profile.targetInputTokens == 120_000, "DeepSeek target input should be 120K tokens")
check(deepSeekPlan.profile.hardInputTokens == 180_000, "DeepSeek hard input should be 180K tokens")
check(deepSeekPlan.profile.disablesThinking, "DeepSeek thinking should be disabled")
check(deepSeekPlan.totalChunks == 1, "DeepSeek should avoid 2000-character chunking")

let unknownTranscript = String(
    repeating: "这是一段中文转录文本，用来验证未知模型会使用保守分块策略。\n",
    count: 1_000
)
let unknownPlan = RefinePlanner.makePlan(
    text: unknownTranscript,
    model: "unknown-model",
    baseURL: "https://example.com"
)
check(unknownPlan.profile.targetInputTokens == 8_000, "Unknown model target input should be conservative")
check(unknownPlan.profile.hardInputTokens == 12_000, "Unknown model hard input should be conservative")
check(unknownPlan.totalChunks > 1, "Unknown model should split long transcripts")
check(unknownPlan.totalChunks == unknownPlan.chunks.count, "Plan should know the real call count before refine starts")
check(
    unknownPlan.totalCharacters == unknownPlan.chunks.reduce(0) { $0 + $1.characterCount },
    "Plan total characters should match chunk progress accounting"
)

let streamLine = #"data: {"choices":[{"delta":{"content":"你好"}}]}"#
check(RefineStreamParser.contentDelta(from: streamLine) == "你好", "Streaming parser should read content deltas")
check(RefineStreamParser.contentDelta(from: "data: [DONE]") == nil, "Streaming parser should ignore done events")

check(
    RefineProgress(currentChunk: 1, totalChunks: 2, processedCharacters: 50, totalCharacters: 100).fraction == 0.5,
    "Progress fraction should match processed characters"
)
check(
    RefineProgress(currentChunk: 2, totalChunks: 2, processedCharacters: 150, totalCharacters: 100).fraction == 1,
    "Progress fraction should clamp at 100%"
)

print("Refine planner checks passed.")
