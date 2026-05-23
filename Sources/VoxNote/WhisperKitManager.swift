import Foundation
@preconcurrency import WhisperKit

final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func reset() {
        lock.lock()
        cancelled = false
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        let value = cancelled
        lock.unlock()
        return value
    }
}

final class WhisperKitManager: @unchecked Sendable {
    private let cancellationFlag = CancellationFlag()

    func transcribe(
        audioArray: [Float],
        language: String?,
        onProgress: @escaping @Sendable (Double, String) -> Void,
        onSegment: @escaping @Sendable ([TranscriptionSegment]) -> Void
    ) async throws -> [TranscriptionResult] {
        guard let whisperKit = AppModelManager.shared.whisperKit else {
            throw AppError.noWhisperKit
        }

        cancellationFlag.reset()
        var options = DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: language,
            detectLanguage: language == nil,
            wordTimestamps: true,
            concurrentWorkerCount: 16,
            chunkingStrategy: .vad
        )
        options.skipSpecialTokens = true
        let progressObject = whisperKit.progress

        let callback: TranscriptionCallback = { [cancellationFlag] progress in
            if cancellationFlag.isCancelled {
                return false
            }
            let fraction = min(0.98, max(0.02, progressObject.fractionCompleted))
            onProgress(fraction, progress.text)
            return nil
        }

        let segmentCallback: SegmentDiscoveryCallback = { segments in
            onSegment(segments)
        }

        let results = try await whisperKit.transcribe(
            audioArray: audioArray,
            decodeOptions: options,
            callback: callback,
            segmentCallback: segmentCallback
        )
        onProgress(1, results.map(\.text).joined(separator: "\n"))
        return results
    }

    func cancel() {
        cancellationFlag.cancel()
    }

    func detectLanguage(audioArray: [Float]) async throws -> String {
        guard let whisperKit = AppModelManager.shared.whisperKit else {
            throw AppError.noWhisperKit
        }
        return try await whisperKit.detectLangauge(audioArray: audioArray).language
    }
}
