import AVFoundation
import Foundation
import os
@preconcurrency import SpeakerKit
@preconcurrency import WhisperKit

final class TranscriptionOrchestrator: @unchecked Sendable {
    static let shared = TranscriptionOrchestrator()

    var onStateChange: ((VoxTranscriptionState) -> Void)?

    private let logger = Logger(subsystem: "com.VoxNote.app", category: "Transcription")
    private let whisperManager = WhisperKitManager()
    private let speakerManager = SpeakerKitManager()
    private let videoAudioExtractor = VideoAudioExtractor()
    private let streamingTranscriber = StreamingTranscriber()
    private let stateLock = NSLock()

    private var currentTask: Task<Void, Never>?
    private var currentState: VoxTranscriptionState = .idle
    private(set) var currentSourceName = "Transcription"
    private(set) var currentSourceURL: URL?
    private var recordingDirectoryURL: URL?

    private init() {
        streamingTranscriber.onStateChange = { [weak self] state in
            self?.emit(.recording(
                confirmedText: state.confirmedText,
                pendingText: state.pendingText,
                duration: state.duration
            ))
        }
    }

    func transcribe(fileURL: URL) {
        cancel()
        currentSourceName = fileURL.deletingPathExtension().lastPathComponent
        currentSourceURL = fileURL
        currentTask = Task { [weak self] in
            await self?.runFileTranscription(fileURL: fileURL)
        }
    }

    func setRecordingDirectory(_ url: URL?) {
        recordingDirectoryURL = url
    }

    func startRecording() {
        guard !streamingTranscriber.isRecording else { return }
        cancel()
        currentSourceName = Self.defaultRecordingBaseName()
        currentSourceURL = nil
        currentTask = Task { [weak self] in
            await self?.runStartRecording()
        }
    }

    func stopRecording() {
        guard streamingTranscriber.isRecording else { return }
        currentTask?.cancel()
        currentTask = Task { [weak self] in
            await self?.runStopRecording()
        }
    }

    func cancel() {
        currentTask?.cancel()
        currentTask = nil
        whisperManager.cancel()
        speakerManager.cancel()
        if streamingTranscriber.isRecording {
            Task {
                _ = await streamingTranscriber.stopRecording()
            }
        }
    }

    private func runFileTranscription(fileURL: URL) async {
        var tempAudioURL: URL?
        do {
            guard VideoAudioExtractor.isSupportedFile(fileURL) else {
                throw AppError.exportFailed("Unsupported file type.")
            }

            let audioURL: URL
            if VideoAudioExtractor.isVideoFile(fileURL) {
                emit(.extractingAudio)
                let extracted = try await videoAudioExtractor.extractAudio(from: fileURL)
                tempAudioURL = extracted
                audioURL = extracted
            } else {
                audioURL = fileURL
            }

            try Task.checkCancellation()
            emit(.preparingAudio)
            let audioArray = try AudioProcessor.loadAudioAsFloatArray(fromPath: audioURL.path)

            try await ensureWhisperReady()
            try Task.checkCancellation()

            let finalText = try await transcribeAndPostProcess(
                audioArray: audioArray,
                recordingSegments: nil,
                fallbackText: nil
            )

            emit(.completed(finalText))
            AppModelManager.shared.scheduleAutoUnload(after: 600)
        } catch is CancellationError {
            emit(.idle)
        } catch {
            logger.error("File transcription failed: \(error.localizedDescription, privacy: .public)")
            emit(.error(error.localizedDescription))
        }

        if let tempAudioURL {
            videoAudioExtractor.cleanup(tempURL: tempAudioURL)
        }
    }

    private func runStartRecording() async {
        do {
            try await ensureWhisperReady()
            try Task.checkCancellation()
            try await streamingTranscriber.startRecording(language: LanguageManager.shared.whisperLanguage)
        } catch is CancellationError {
            emit(.idle)
        } catch {
            logger.error("Recording failed to start: \(error.localizedDescription, privacy: .public)")
            emit(.error(error.localizedDescription))
        }
    }

    private func runStopRecording() async {
        let result = await streamingTranscriber.stopRecording()
        do {
            if let recordingURL = try saveRecording(result) {
                currentSourceURL = recordingURL
                currentSourceName = recordingURL.deletingPathExtension().lastPathComponent
            }
            let text = try await postProcessRecording(result)
            emit(.completed(text))
            AppModelManager.shared.scheduleAutoUnload(after: 600)
        } catch is CancellationError {
            emit(.idle)
        } catch {
            logger.error("Recording post-processing failed: \(error.localizedDescription, privacy: .public)")
            let fallback = result.finalText.trimmingCharacters(in: .whitespacesAndNewlines)
            emit(.completed(fallback))
        }
    }

    private func ensureWhisperReady() async throws {
        try await AppModelManager.shared.ensureWhisperKitReady { [weak self] state in
            switch state {
            case .downloading(let progress):
                self?.emit(.downloadingModel(progress: progress))
            case .loading:
                self?.emit(.loadingModel)
            case .ready:
                break
            case .error(let message):
                self?.emit(.error(message))
            case .notDownloaded, .downloaded:
                break
            }
        }
    }

    private func transcribeAndPostProcess(
        audioArray: [Float],
        recordingSegments: [TranscriptionSegment]?,
        fallbackText: String?
    ) async throws -> String {
        let speakerEnabled = UserDefaults.standard.bool(forKey: "speakerDiarizationEnabled")
        let diarizationTask: Task<DiarizationResult?, Never>? = speakerEnabled ? Task {
            do {
                return try await speakerManager.diarize(audioArray: audioArray) { _ in }
            } catch {
                self.logger.error("Speaker diarization failed: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        } : nil

        let transcriptionResults: [TranscriptionResult]
        if let recordingSegments {
            let text = fallbackText ?? recordingSegments.map(\.text).joined(separator: "\n")
            transcriptionResults = [
                TranscriptionResult(
                    text: text,
                    segments: recordingSegments,
                    language: LanguageManager.shared.whisperLanguage ?? "",
                    timings: TranscriptionTimings()
                )
            ]
        } else {
            transcriptionResults = try await whisperManager.transcribe(
                audioArray: audioArray,
                language: LanguageManager.shared.whisperLanguage,
                onProgress: { [weak self] progress, partialText in
                    self?.emit(.transcribing(progress: progress, partialText: partialText))
                },
                onSegment: { [weak self] segments in
                    let text = segments.map(\.text).joined(separator: "\n")
                    self?.emit(.transcribing(progress: 0.98, partialText: text))
                }
            )
        }

        var finalText = transcriptionResults
            .map(\.text)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let diarizationTask {
            emit(.diarizing(progress: 0))
            if let diarization = await diarizationTask.value {
                finalText = speakerManager.combinedText(
                    diarization: diarization,
                    transcription: transcriptionResults
                )
            }
            emit(.diarizing(progress: 1))
        }

        if LLMService.shared.isEnabled && !finalText.isEmpty {
            do {
                emit(.refining)
                finalText = try await LLMService.shared.refine(text: finalText)
            } catch {
                logger.error("LLM refinement failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        return finalText
    }

    private func postProcessRecording(_ result: StreamingResult) async throws -> String {
        let fallback = result.finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.audioArray.isEmpty else {
            return fallback
        }

        if result.segments.isEmpty {
            var text = fallback
            if LLMService.shared.isEnabled && !text.isEmpty {
                do {
                    emit(.refining)
                    text = try await LLMService.shared.refine(text: text)
                } catch {
                    logger.error("LLM refinement failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            return text
        }

        return try await transcribeAndPostProcess(
            audioArray: result.audioArray,
            recordingSegments: result.segments,
            fallbackText: fallback
        )
    }

    private func saveRecording(_ result: StreamingResult) throws -> URL? {
        guard !result.audioArray.isEmpty else { return nil }
        guard let directory = recordingDirectoryURL else { return nil }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let baseName = Self.defaultRecordingBaseName()
        let outputURL = uniqueFileURL(in: directory, baseName: baseName, extension: "wav")

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else {
            throw AppError.exportFailed("Could not create a recording audio format.")
        }

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(result.audioArray.count)
        ) else {
            throw AppError.exportFailed("Could not create a recording audio buffer.")
        }

        buffer.frameLength = AVAudioFrameCount(result.audioArray.count)
        if let channel = buffer.floatChannelData?[0] {
            result.audioArray.withUnsafeBufferPointer { samples in
                channel.update(from: samples.baseAddress!, count: samples.count)
            }
        }

        let file = try AVAudioFile(forWriting: outputURL, settings: format.settings)
        try file.write(from: buffer)
        return outputURL
    }

    private func uniqueFileURL(in directory: URL, baseName: String, extension ext: String) -> URL {
        var candidate = directory
            .appendingPathComponent(baseName)
            .appendingPathExtension(ext)
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory
                .appendingPathComponent("\(baseName) \(index)")
                .appendingPathExtension(ext)
            index += 1
        }
        return candidate
    }

    private static func defaultRecordingBaseName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return "Recording \(formatter.string(from: Date()))"
    }

    private func emit(_ state: VoxTranscriptionState) {
        stateLock.lock()
        currentState = state
        stateLock.unlock()
        DispatchQueue.main.async { [weak self] in
            self?.onStateChange?(state)
        }
    }
}
