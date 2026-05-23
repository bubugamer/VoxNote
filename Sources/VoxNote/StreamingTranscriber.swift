import Foundation
@preconcurrency import WhisperKit

final class StreamingTranscriber: @unchecked Sendable {
    var onStateChange: ((StreamingState) -> Void)?

    private let lock = NSLock()
    private var streamTask: Task<Void, Never>?
    private var durationTask: Task<Void, Never>?
    private var transcriber: AudioStreamTranscriber?
    private var startDate: Date?
    private var confirmedText = ""
    private var pendingText = ""
    private var latestSegments: [TranscriptionSegment] = []
    private var recording = false

    var isRecording: Bool {
        locked { recording }
    }

    var recordingDuration: TimeInterval {
        let date = locked { startDate }
        return date.map { Date().timeIntervalSince($0) } ?? 0
    }

    func startRecording(language: String?) async throws {
        guard !isRecording else { return }
        try await PermissionManager.shared.ensureMicrophoneAccess()

        guard let whisperKit = AppModelManager.shared.whisperKit else {
            throw AppError.noWhisperKit
        }
        guard let tokenizer = whisperKit.tokenizer else {
            throw AppError.noWhisperKit
        }

        var options = DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: language,
            detectLanguage: language == nil,
            wordTimestamps: true
        )
        options.skipSpecialTokens = true

        let audioStreamTranscriber = AudioStreamTranscriber(
            audioEncoder: whisperKit.audioEncoder,
            featureExtractor: whisperKit.featureExtractor,
            segmentSeeker: whisperKit.segmentSeeker,
            textDecoder: whisperKit.textDecoder,
            tokenizer: tokenizer,
            audioProcessor: whisperKit.audioProcessor,
            decodingOptions: options,
            requiredSegmentsForConfirmation: 2,
            silenceThreshold: 0.3,
            useVAD: true
        ) { [weak self] _, newState in
            self?.receive(streamState: newState)
        }

        locked {
            transcriber = audioStreamTranscriber
            confirmedText = ""
            pendingText = ""
            latestSegments = []
            startDate = Date()
            recording = true
        }

        streamTask = Task { [audioStreamTranscriber] in
            do {
                try await audioStreamTranscriber.startStreamTranscription()
            } catch {
                // The orchestrator owns visible errors. This task may end normally
                // after stopRecording flips the actor state.
            }
        }

        durationTask = Task { [weak self] in
            while !(Task.isCancelled) {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self, self.isRecording else { break }
                self.emitCurrentState()
            }
        }

        emitCurrentState()
    }

    func stopRecording() async -> StreamingResult {
        let localTranscriber: AudioStreamTranscriber?
        localTranscriber = locked {
            recording = false
            return transcriber
        }

        durationTask?.cancel()
        durationTask = nil

        if let localTranscriber {
            await localTranscriber.stopStreamTranscription()
        }

        streamTask?.cancel()
        streamTask = nil

        let audioArray: [Float]
        if let whisperKit = AppModelManager.shared.whisperKit {
            audioArray = Array(whisperKit.audioProcessor.audioSamples)
        } else {
            audioArray = []
        }

        let snapshot = locked { () -> (TimeInterval, String, [TranscriptionSegment]) in
            let duration = startDate.map { Date().timeIntervalSince($0) } ?? 0
            let finalText = [confirmedText, pendingText]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && $0 != "Waiting for speech..." }
                .joined(separator: "\n")
            let segments = latestSegments
            transcriber = nil
            startDate = nil
            pendingText = ""
            latestSegments = []
            return (duration, finalText, segments)
        }

        return StreamingResult(finalText: snapshot.1, segments: snapshot.2, audioArray: audioArray, duration: snapshot.0)
    }

    private func receive(streamState: AudioStreamTranscriber.State) {
        let confirmed = streamState.confirmedSegments
            .map(\.text)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let pendingSegments = streamState.unconfirmedSegments
            .map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let pendingParts = [pendingSegments, streamState.currentText]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let pending = pendingParts.joined(separator: " ")

        locked {
            confirmedText = confirmed
            pendingText = pending
            latestSegments = streamState.confirmedSegments + streamState.unconfirmedSegments
            recording = streamState.isRecording || recording
        }

        emitCurrentState()
    }

    private func emitCurrentState() {
        let state = locked {
            StreamingState(
                confirmedText: confirmedText,
                pendingText: pendingText,
                duration: startDate.map { Date().timeIntervalSince($0) } ?? 0,
                isRecording: recording
            )
        }
        onStateChange?(state)
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
