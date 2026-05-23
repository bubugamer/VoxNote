import Foundation
@preconcurrency import SpeakerKit
@preconcurrency import WhisperKit

final class SpeakerKitManager: @unchecked Sendable {
    private let cancellationFlag = CancellationFlag()

    func diarize(
        audioArray: [Float],
        numberOfSpeakers: Int? = nil,
        progressCallback: @escaping @Sendable (Double) -> Void
    ) async throws -> DiarizationResult {
        cancellationFlag.reset()
        try await AppModelManager.shared.ensureSpeakerKitReady { progress in
            progressCallback(progress * 0.4)
        }

        guard let speakerKit = AppModelManager.shared.speakerKit else {
            throw AppError.exportFailed("Speaker model is not ready.")
        }

        let options = PyannoteDiarizationOptions(numberOfSpeakers: numberOfSpeakers)
        return try await speakerKit.diarize(audioArray: audioArray, options: options) { progress in
            progressCallback(0.4 + min(0.6, max(0, progress.fractionCompleted * 0.6)))
        }
    }

    func combinedText(
        diarization: DiarizationResult,
        transcription: [TranscriptionResult]
    ) -> String {
        let speakerSegments = diarization.addSpeakerInfo(to: transcription, strategy: .subsegment).flatMap { $0 }
        guard !speakerSegments.isEmpty else {
            return transcription.map(\.text).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var output = ""
        var previousSpeaker: Int?

        for segment in speakerSegments {
            let speakerNumber = (segment.speaker.speakerId ?? 0) + 1
            let rawText = segment.text.isEmpty ? (segment.transcription?.text ?? "") : segment.text
            let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            if previousSpeaker != speakerNumber {
                if !output.isEmpty {
                    output.append("\n")
                }
                output.append("【Speaker \(speakerNumber)】")
                previousSpeaker = speakerNumber
            }

            if output.hasSuffix("】") {
                output.append(text)
            } else if text.first?.isPunctuation == true {
                output.append(text)
            } else {
                output.append(" ")
                output.append(text)
            }
        }

        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func cancel() {
        cancellationFlag.cancel()
    }
}
