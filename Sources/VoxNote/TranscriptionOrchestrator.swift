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
    private var pendingRecording: PendingRecording?
    private var activeOperationID: UUID?

    var hasUnsavedRecording: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return pendingRecording != nil
    }

    private init() {
        streamingTranscriber.onStateChange = { [weak self] state in
            self?.emit(.recording(
                confirmedText: state.confirmedText,
                pendingText: state.pendingText,
                duration: state.duration,
                isPaused: state.isPaused,
                modelState: state.modelState
            ))
        }
        streamingTranscriber.onError = { [weak self] error in
            self?.logger.error("Recording stream failed: \(error.localizedDescription, privacy: .public)")
            self?.emit(.error(error.localizedDescription))
        }
    }

    func transcribe(fileURL: URL) {
        cancel()
        let operationID = beginOperation()
        currentSourceName = fileURL.deletingPathExtension().lastPathComponent
        currentSourceURL = fileURL
        currentTask = Task { [weak self] in
            await self?.runFileTranscription(fileURL: fileURL, operationID: operationID)
        }
    }

    func setRecordingDirectory(_ url: URL?) {
        recordingDirectoryURL = url
    }

    @discardableResult
    func startRecording() -> Bool {
        guard !streamingTranscriber.isRecording else { return false }
        guard AppModelManager.shared.canStartRealtimeRecording else { return false }
        cancel()
        AppModelManager.shared.cancelAutoUnload()
        currentSourceName = Self.defaultRecordingBaseName()
        currentSourceURL = nil
        setPendingRecording(nil)
        let operationID = beginOperation()
        currentTask = Task { [weak self] in
            await self?.runStartRecording(operationID: operationID)
        }
        return true
    }

    func pauseRecording() {
        streamingTranscriber.pauseRecording()
    }

    func resumeRecording() {
        do {
            try streamingTranscriber.resumeRecording()
        } catch {
            logger.error("Recording failed to resume: \(error.localizedDescription, privacy: .public)")
            emit(.error(error.localizedDescription))
        }
    }

    func stopRecording() {
        clearActiveOperation()
        currentTask?.cancel()
        currentTask = nil
        guard streamingTranscriber.isRecording else {
            emit(.idle)
            return
        }
        currentTask = Task { [weak self] in
            await self?.runStopRecording()
        }
    }

    func savePendingRecording(to directory: URL) throws -> URL {
        guard let recording = lockedPendingRecording() else {
            throw AppError.exportFailed("There is no unsaved recording audio.")
        }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let outputURL = uniqueFileURL(in: directory, baseName: recording.baseName, extension: "m4a")
        do {
            try RecordingAudioWriter.writeM4A(samples: recording.audioArray, to: outputURL)
            currentSourceURL = outputURL
            currentSourceName = outputURL.deletingPathExtension().lastPathComponent
            setPendingRecording(nil)
            return outputURL
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
    }

    func discardPendingRecording() {
        setPendingRecording(nil)
    }

    func cancel() {
        clearActiveOperation()
        currentTask?.cancel()
        currentTask = nil
        whisperManager.cancel()
        speakerManager.cancel()
        if streamingTranscriber.isRecording {
            Task {
                _ = await streamingTranscriber.stopRecording()
            }
        }
        setPendingRecording(nil)
    }

    private func runFileTranscription(fileURL: URL, operationID: UUID) async {
        var tempAudioURL: URL?
        do {
            guard VideoAudioExtractor.isSupportedFile(fileURL) else {
                throw AppError.exportFailed("Unsupported file type.")
            }

            let audioURL: URL
            if VideoAudioExtractor.isVideoFile(fileURL) {
                emit(.extractingAudio, operationID: operationID)
                let extracted = try await videoAudioExtractor.extractAudio(from: fileURL)
                tempAudioURL = extracted
                audioURL = extracted
            } else {
                audioURL = fileURL
            }

            try Task.checkCancellation()
            emit(.preparingAudio, operationID: operationID)
            let audioArray = try AudioProcessor.loadAudioAsFloatArray(fromPath: audioURL.path)

            try await ensureWhisperReady(operationID: operationID)
            try Task.checkCancellation()
            try checkCurrentOperation(operationID)

            let finalText = try await transcribeAndPostProcess(
                audioArray: audioArray,
                recordingSegments: nil,
                fallbackText: nil,
                operationID: operationID
            )

            emit(.completed(finalText), operationID: operationID)
            clearActiveOperation(matching: operationID)
            AppModelManager.shared.scheduleAutoUnload(after: 600)
        } catch is CancellationError {
            emit(.idle, operationID: operationID)
            clearActiveOperation(matching: operationID)
        } catch {
            logger.error("File transcription failed: \(error.localizedDescription, privacy: .public)")
            emit(.error(error.localizedDescription), operationID: operationID)
            clearActiveOperation(matching: operationID)
        }

        if let tempAudioURL {
            videoAudioExtractor.cleanup(tempURL: tempAudioURL)
        }
    }

    private func runStartRecording(operationID: UUID) async {
        do {
            guard let directory = recordingDirectoryURL else {
                throw AppError.exportFailed("Choose a folder before recording.")
            }
            guard AppModelManager.shared.canStartRealtimeRecording else {
                throw AppError.noWhisperKit
            }

            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            emit(.preparingAudio, operationID: operationID)
            try await PermissionManager.shared.ensureMicrophoneAccess()
            try Task.checkCancellation()
            try checkCurrentOperation(operationID)

            try await streamingTranscriber.startRecording(language: LanguageManager.shared.whisperLanguage)
            streamingTranscriber.updateModelState(.ready)

            try Task.checkCancellation()
            try checkCurrentOperation(operationID)
            clearActiveOperation(matching: operationID)
        } catch is CancellationError {
            emit(.idle, operationID: operationID)
            clearActiveOperation(matching: operationID)
        } catch {
            logger.error("Recording failed to start: \(error.localizedDescription, privacy: .public)")
            emit(.error(error.localizedDescription), operationID: operationID)
            clearActiveOperation(matching: operationID)
        }
    }

    private func runStopRecording() async {
        guard !Task.isCancelled else { return }

        let result = await streamingTranscriber.stopRecording()
        let finalText = result.finalText.trimmingCharacters(in: .whitespacesAndNewlines)

        if !result.audioArray.isEmpty {
            setPendingRecording(PendingRecording(
                baseName: currentSourceName,
                audioArray: result.audioArray
            ))
        } else {
            setPendingRecording(nil)
        }

        emit(.completed(finalText))
        AppModelManager.shared.scheduleAutoUnload(after: 600)
    }

    private func ensureWhisperReady(operationID: UUID, forRecording: Bool = false) async throws {
        try await AppModelManager.shared.ensureWhisperKitReady { [weak self] state in
            guard self?.isCurrentOperation(operationID) == true else { return }
            if forRecording {
                self?.streamingTranscriber.updateModelState(state)
            } else {
                switch state {
                case .downloading(let progress):
                    self?.emit(.downloadingModel(progress: progress), operationID: operationID)
                case .loading:
                    self?.emit(.loadingModel, operationID: operationID)
                case .ready:
                    break
                case .error(let message):
                    self?.emit(.error(message), operationID: operationID)
                case .notDownloaded, .downloaded:
                    break
                }
            }
        }
        try checkCurrentOperation(operationID)
        if forRecording {
            streamingTranscriber.updateModelState(.ready)
        }
    }

    private func transcribeAndPostProcess(
        audioArray: [Float],
        recordingSegments: [TranscriptionSegment]?,
        fallbackText: String?,
        operationID: UUID
    ) async throws -> String {
        guard AudioSignal.containsNonSilentSamples(audioArray) else {
            return ""
        }

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
                    self?.emit(.transcribing(progress: progress, partialText: partialText), operationID: operationID)
                },
                onSegment: { [weak self] segments in
                    let text = segments.map(\.text).joined(separator: "\n")
                    self?.emit(.transcribing(progress: 0.98, partialText: text), operationID: operationID)
                }
            )
        }

        var finalText = transcriptionResults
            .map(\.text)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let diarizationTask {
            emit(.diarizing(progress: 0), operationID: operationID)
            if let diarization = await diarizationTask.value {
                finalText = speakerManager.combinedText(
                    diarization: diarization,
                    transcription: transcriptionResults
                )
            }
            emit(.diarizing(progress: 1), operationID: operationID)
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

    private static func defaultRecordingBaseName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return "Recording \(formatter.string(from: Date()))"
    }

    private func lockedPendingRecording() -> PendingRecording? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return pendingRecording
    }

    private func setPendingRecording(_ recording: PendingRecording?) {
        stateLock.lock()
        pendingRecording = recording
        stateLock.unlock()
    }

    private func beginOperation() -> UUID {
        let operationID = UUID()
        stateLock.lock()
        activeOperationID = operationID
        stateLock.unlock()
        return operationID
    }

    private func isCurrentOperation(_ operationID: UUID) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return activeOperationID == operationID
    }

    private func checkCurrentOperation(_ operationID: UUID) throws {
        if !isCurrentOperation(operationID) {
            throw CancellationError()
        }
    }

    private func clearActiveOperation(matching operationID: UUID? = nil) {
        stateLock.lock()
        if operationID == nil || activeOperationID == operationID {
            activeOperationID = nil
        }
        stateLock.unlock()
    }

    private func emit(_ state: VoxTranscriptionState, operationID: UUID? = nil) {
        stateLock.lock()
        if let operationID, activeOperationID != operationID {
            stateLock.unlock()
            return
        }
        currentState = state
        stateLock.unlock()
        DispatchQueue.main.async { [weak self] in
            self?.onStateChange?(state)
        }
    }
}

private struct PendingRecording {
    let baseName: String
    let audioArray: [Float]
}

private enum RecordingAudioWriter {
    static func writeM4A(samples: [Float], to url: URL) throws {
        guard !samples.isEmpty else {
            throw AppError.exportFailed("No recorded audio is available to save.")
        }
        guard let inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(WhisperKit.sampleRate),
            channels: 1,
            interleaved: false
        ) else {
            throw AppError.exportFailed("Could not prepare the recorded audio for saving.")
        }

        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: WhisperKit.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        let file = try AVAudioFile(
            forWriting: url,
            settings: outputSettings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let chunkSize = 1_048_576
        var offset = 0
        while offset < samples.count {
            let frameCount = min(chunkSize, samples.count - offset)
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: inputFormat,
                frameCapacity: AVAudioFrameCount(frameCount)
            ) else {
                throw AppError.exportFailed("Could not prepare the recorded audio for saving.")
            }
            buffer.frameLength = AVAudioFrameCount(frameCount)
            guard let channel = buffer.floatChannelData?[0] else {
                throw AppError.exportFailed("Could not prepare the recorded audio for saving.")
            }
            samples.withUnsafeBufferPointer { source in
                if let baseAddress = source.baseAddress {
                    channel.update(from: baseAddress.advanced(by: offset), count: frameCount)
                }
            }
            try file.write(from: buffer)
            offset += frameCount
        }
    }
}
