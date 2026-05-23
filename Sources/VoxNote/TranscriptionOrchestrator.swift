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
    private let fileRecorder = FileAudioRecorder()
    private let stateLock = NSLock()

    private var currentTask: Task<Void, Never>?
    private var recordingTimerTask: Task<Void, Never>?
    private var currentState: VoxTranscriptionState = .idle
    private(set) var currentSourceName = "Transcription"
    private(set) var currentSourceURL: URL?
    private var recordingDirectoryURL: URL?

    private init() {}

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
        guard !fileRecorder.isRecording else { return }
        cancel()
        currentSourceName = Self.defaultRecordingBaseName()
        currentSourceURL = nil
        currentTask = Task { [weak self] in
            await self?.runStartRecording()
        }
    }

    func stopRecording() {
        // Cancel any in-progress start task (covers the mic-permission phase
        // where fileRecorder.isRecording is still false)
        currentTask?.cancel()
        currentTask = nil
        guard fileRecorder.isRecording else { return }
        currentTask = Task { [weak self] in
            await self?.runStopRecording()
        }
    }

    func cancel() {
        currentTask?.cancel()
        currentTask = nil
        recordingTimerTask?.cancel()
        recordingTimerTask = nil
        whisperManager.cancel()
        speakerManager.cancel()
        if fileRecorder.isRecording {
            _ = fileRecorder.stop()
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
            guard let directory = recordingDirectoryURL else {
                throw AppError.exportFailed("Choose a folder before recording.")
            }

            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try await PermissionManager.shared.ensureMicrophoneAccess()
            try Task.checkCancellation()

            let baseName = Self.defaultRecordingBaseName()
            let outputURL = uniqueFileURL(in: directory, baseName: baseName, extension: "m4a")
            try fileRecorder.start(url: outputURL)

            currentSourceURL = outputURL
            currentSourceName = outputURL.deletingPathExtension().lastPathComponent
            startRecordingTimer(startedAt: Date())
            emit(.recording(confirmedText: "", pendingText: "", duration: 0))
        } catch is CancellationError {
            emit(.idle)
        } catch {
            logger.error("Recording failed to start: \(error.localizedDescription, privacy: .public)")
            emit(.error(error.localizedDescription))
        }
    }

    private func runStopRecording() async {
        recordingTimerTask?.cancel()
        recordingTimerTask = nil

        // If cancel() was called concurrently it already stopped the recorder;
        // bail out rather than emitting a spurious error for a saved file.
        guard !Task.isCancelled else { return }

        guard let recordingURL = fileRecorder.stop() else {
            emit(.error("Recording could not be saved."))
            return
        }

        currentSourceURL = recordingURL
        currentSourceName = recordingURL.deletingPathExtension().lastPathComponent
        await runFileTranscription(fileURL: recordingURL)
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

    private func startRecordingTimer(startedAt: Date) {
        recordingTimerTask?.cancel()
        recordingTimerTask = Task { [weak self] in
            do {
                while true {
                    try await Task.sleep(nanoseconds: 200_000_000)
                    guard let self, self.fileRecorder.isRecording else { break }
                    self.emit(.recording(
                        confirmedText: "",
                        pendingText: "",
                        duration: Date().timeIntervalSince(startedAt)
                    ))
                }
            } catch {
                // Task was cancelled — exit without emitting stale state
            }
        }
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

private final class FileAudioRecorder: NSObject, @unchecked Sendable {
    private let lock = NSLock()
    private var recorder: AVAudioRecorder?
    private var recordingURL: URL?

    var isRecording: Bool {
        lock.lock()
        defer { lock.unlock() }
        return recorder?.isRecording == true
    }

    func start(url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        let newRecorder = try AVAudioRecorder(url: url, settings: settings)
        newRecorder.isMeteringEnabled = true
        newRecorder.prepareToRecord()

        // Hold the lock while calling record() so that recorder is visible to
        // concurrent isRecording / stop() calls the instant recording goes live.
        lock.lock()
        defer { lock.unlock() }
        guard newRecorder.record() else {
            throw AppError.exportFailed("Recording could not start.")
        }
        recorder = newRecorder
        recordingURL = url
    }

    func stop() -> URL? {
        lock.lock()
        let localRecorder = recorder
        let url = recordingURL
        recorder = nil
        recordingURL = nil
        lock.unlock()

        localRecorder?.stop()
        return url
    }
}
