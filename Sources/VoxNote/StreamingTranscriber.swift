import AVFoundation
import Foundation
@preconcurrency import WhisperKit

final class StreamingTranscriber: @unchecked Sendable {
    var onStateChange: ((StreamingState) -> Void)?
    var onError: ((Error) -> Void)?

    private enum TranscriptionWork {
        case none
        case preview(samples: [Float], sampleCount: Int)
        case commit(samples: [Float], startSample: Int, endSample: Int)
    }

    private struct ChunkResult {
        let text: String
        let segments: [TranscriptionSegment]
    }

    private let lock = NSLock()
    private var capture: LiveAudioCapture?
    private var durationTask: Task<Void, Never>?
    private var transcriptionTask: Task<Void, Never>?
    private var activeSessionID: UUID?
    private var language: String?
    private var startedAt: Date?
    private var accumulatedDuration: TimeInterval = 0
    private var confirmedText = ""
    private var pendingText = ""
    private var latestSegments: [TranscriptionSegment] = []
    private var finalizedSampleCount = 0
    private var lastPreviewSampleCount = 0
    private var recording = false
    private var paused = false
    private var modelState: AppModelManagerState = .notDownloaded

    private let minimumPreviewSamples = WhisperKit.sampleRate * 2
    private let previewStepSamples = WhisperKit.sampleRate * 3
    private let commitIntervalSamples = WhisperKit.sampleRate * 12
    private let minimumFinalSamples = WhisperKit.sampleRate / 2

    var isRecording: Bool {
        locked { recording }
    }

    var recordingDuration: TimeInterval {
        currentDuration()
    }

    func startRecording(language: String?) async throws {
        guard !isRecording else { return }
        try await PermissionManager.shared.ensureMicrophoneAccess()

        let sessionID = UUID()
        let audioCapture = LiveAudioCapture()
        do {
            try audioCapture.start { [weak self] error in
                self?.handleRuntimeError(error, sessionID: sessionID)
            }
        } catch let appError as AppError {
            throw appError
        } catch {
            throw AppError.recordingStartFailed
        }

        locked {
            capture = audioCapture
            activeSessionID = sessionID
            self.language = language
            startedAt = Date()
            accumulatedDuration = 0
            confirmedText = ""
            pendingText = ""
            latestSegments = []
            finalizedSampleCount = 0
            lastPreviewSampleCount = 0
            recording = true
            paused = false
            modelState = AppModelManager.shared.whisperModelState
        }

        durationTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard let self, self.isRecording else { break }
                self.emitCurrentState()
            }
        }

        transcriptionTask = Task { [weak self] in
            await self?.runTranscriptionLoop(sessionID: sessionID)
        }

        emitCurrentState()
    }

    func updateModelState(_ state: AppModelManagerState) {
        locked {
            modelState = state
        }
        emitCurrentState()
    }

    func pauseRecording() {
        let audioCapture = locked { () -> LiveAudioCapture? in
            guard recording, !paused else { return nil }
            if let startedAt {
                accumulatedDuration += Date().timeIntervalSince(startedAt)
            }
            self.startedAt = nil
            paused = true
            return capture
        }
        audioCapture?.pause()
        emitCurrentState()
    }

    func resumeRecording() throws {
        let audioCapture = locked { () -> LiveAudioCapture? in
            guard recording, paused else { return nil }
            return capture
        }

        guard let audioCapture else { return }
        do {
            try audioCapture.resume()
            locked {
                if recording, paused {
                    startedAt = Date()
                    paused = false
                }
            }
            emitCurrentState()
        } catch {
            handleRuntimeError(AppError.recordingStoppedUnexpectedly, sessionID: locked { activeSessionID })
            throw AppError.recordingStoppedUnexpectedly
        }
    }

    func stopRecording() async -> StreamingResult {
        let snapshot = locked { () -> (UUID?, LiveAudioCapture?, String?, Int, TimeInterval) in
            let sessionID = activeSessionID
            let audioCapture = capture
            let selectedLanguage = language
            let finalized = finalizedSampleCount
            let duration = currentDurationLocked()
            recording = false
            paused = false
            startedAt = nil
            activeSessionID = nil
            return (sessionID, audioCapture, selectedLanguage, finalized, duration)
        }

        durationTask?.cancel()
        durationTask = nil

        let audioArray = snapshot.1?.stop() ?? []

        transcriptionTask?.cancel()
        await transcriptionTask?.value
        transcriptionTask = nil

        let finalSnapshot = await finalText(
            audioArray: audioArray,
            finalizedSampleCount: snapshot.3,
            language: snapshot.2
        )

        locked {
            capture = nil
            language = nil
            confirmedText = ""
            pendingText = ""
            latestSegments = []
            finalizedSampleCount = 0
            lastPreviewSampleCount = 0
            accumulatedDuration = 0
        }

        return StreamingResult(
            finalText: finalSnapshot.text,
            segments: finalSnapshot.segments,
            audioArray: audioArray,
            duration: snapshot.4
        )
    }

    private func runTranscriptionLoop(sessionID: UUID) async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { break }

            let work = makeTranscriptionWork(sessionID: sessionID)
            do {
                switch work {
                case .none:
                    continue
                case .preview(let samples, let sampleCount):
                    let result = try await transcribeChunk(samples, language: locked { language })
                    applyPreview(result, sampleCount: sampleCount, sessionID: sessionID)
                case .commit(let samples, let startSample, let endSample):
                    let result = try await transcribeChunk(samples, language: locked { language })
                    applyCommit(result, startSample: startSample, endSample: endSample, sessionID: sessionID)
                }
            } catch is CancellationError {
                break
            } catch {
                continue
            }
        }
    }

    private func makeTranscriptionWork(sessionID: UUID) -> TranscriptionWork {
        let state = locked {
            (
                activeSessionID == sessionID && recording && !paused,
                finalizedSampleCount,
                lastPreviewSampleCount,
                capture,
                modelState
            )
        }
        guard state.0, let audioCapture = state.3, state.4 == .ready else { return .none }

        let samples = audioCapture.snapshotSamples()
        let sampleCount = samples.count
        let unfinalizedCount = sampleCount - state.1
        guard unfinalizedCount >= minimumPreviewSamples else { return .none }

        if unfinalizedCount >= commitIntervalSamples {
            let endSample = min(sampleCount, state.1 + commitIntervalSamples)
            return .commit(
                samples: Array(samples[state.1..<endSample]),
                startSample: state.1,
                endSample: endSample
            )
        }

        guard sampleCount - state.2 >= previewStepSamples else { return .none }
        return .preview(samples: Array(samples[state.1..<sampleCount]), sampleCount: sampleCount)
    }

    private func applyPreview(_ result: ChunkResult, sampleCount: Int, sessionID: UUID) {
        locked {
            guard activeSessionID == sessionID, recording else { return }
            pendingText = result.text
            lastPreviewSampleCount = sampleCount
        }
        emitCurrentState()
    }

    private func applyCommit(_ result: ChunkResult, startSample: Int, endSample: Int, sessionID: UUID) {
        locked {
            guard activeSessionID == sessionID, recording else { return }
            appendConfirmedText(result.text)
            latestSegments.append(contentsOf: Self.offsetSegments(result.segments, by: startSample))
            pendingText = ""
            finalizedSampleCount = endSample
            lastPreviewSampleCount = endSample
        }
        emitCurrentState()
    }

    private func finalText(audioArray: [Float], finalizedSampleCount: Int, language: String?) async -> ChunkResult {
        let existing = locked {
            (
                confirmedText.trimmingCharacters(in: .whitespacesAndNewlines),
                pendingText.trimmingCharacters(in: .whitespacesAndNewlines),
                latestSegments
            )
        }

        let startSample = min(max(0, finalizedSampleCount), audioArray.count)
        let remainingSamples = audioArray.count - startSample
        var finalChunk = ChunkResult(text: "", segments: [])
        if remainingSamples >= minimumFinalSamples {
            do {
                let samples = Array(audioArray[startSample..<audioArray.count])
                finalChunk = try await transcribeChunk(samples, language: language)
                finalChunk = ChunkResult(
                    text: finalChunk.text,
                    segments: Self.offsetSegments(finalChunk.segments, by: startSample)
                )
            } catch {
                finalChunk = ChunkResult(text: "", segments: [])
            }
        }

        let textParts = [
            existing.0,
            finalChunk.text.isEmpty ? existing.1 : finalChunk.text
        ].filter { !$0.isEmpty && $0 != "Waiting for speech..." }

        return ChunkResult(
            text: textParts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines),
            segments: existing.2 + finalChunk.segments
        )
    }

    private func transcribeChunk(_ audioArray: [Float], language: String?) async throws -> ChunkResult {
        try Task.checkCancellation()
        guard !audioArray.isEmpty else {
            return ChunkResult(text: "", segments: [])
        }
        guard AudioSignal.containsNonSilentSamples(audioArray) else {
            return ChunkResult(text: "", segments: [])
        }
        guard let whisperKit = AppModelManager.shared.whisperKit else {
            throw AppError.noWhisperKit
        }

        var options = DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: language,
            detectLanguage: language == nil,
            wordTimestamps: false,
            concurrentWorkerCount: 1
        )
        options.skipSpecialTokens = true

        let results = try await whisperKit.transcribe(audioArray: audioArray, decodeOptions: options)
        try Task.checkCancellation()

        let text = results
            .map(\.text)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let segments = results.flatMap(\.segments)
        return ChunkResult(text: text, segments: segments)
    }

    private func handleRuntimeError(_ error: Error, sessionID: UUID?) {
        let audioCapture = locked { () -> LiveAudioCapture? in
            guard let sessionID, activeSessionID == sessionID else { return nil }
            recording = false
            paused = false
            startedAt = nil
            activeSessionID = nil
            return capture
        }
        audioCapture?.stop()
        durationTask?.cancel()
        transcriptionTask?.cancel()
        onError?(error)
    }

    private func emitCurrentState() {
        let state = locked {
            StreamingState(
                confirmedText: confirmedText,
                pendingText: pendingText,
                duration: currentDurationLocked(),
                isRecording: recording,
                isPaused: paused,
                modelState: modelState
            )
        }
        onStateChange?(state)
    }

    private func currentDuration() -> TimeInterval {
        locked { currentDurationLocked() }
    }

    private func currentDurationLocked() -> TimeInterval {
        guard recording, !paused, let startedAt else {
            return accumulatedDuration
        }
        return accumulatedDuration + Date().timeIntervalSince(startedAt)
    }

    private func appendConfirmedText(_ text: String) {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        if confirmedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            confirmedText = cleaned
        } else {
            confirmedText += "\n" + cleaned
        }
    }

    private static func offsetSegments(_ segments: [TranscriptionSegment], by sampleOffset: Int) -> [TranscriptionSegment] {
        guard sampleOffset > 0 else { return segments }
        let offset = Float(sampleOffset) / Float(WhisperKit.sampleRate)
        return segments.map { segment in
            var adjusted = segment
            adjusted.start += offset
            adjusted.end += offset
            adjusted.seek += sampleOffset
            return adjusted
        }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private final class LiveAudioCapture: @unchecked Sendable {
    private let lock = NSLock()
    private let engine = AVAudioEngine()
    private var samples: [Float] = []
    private var acceptingAudio = false
    private var runtimeErrorHandler: ((Error) -> Void)?

    func start(onRuntimeError: @escaping (Error) -> Void) throws {
        runtimeErrorHandler = onRuntimeError
        samples.removeAll(keepingCapacity: true)

        let inputNode = engine.inputNode
        let tapFormat = inputNode.outputFormat(forBus: 0)
        guard tapFormat.sampleRate > 0, tapFormat.channelCount > 0 else {
            throw AppError.microphoneInputFormatUnavailable
        }

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: tapFormat) { [weak self] buffer, _ in
            self?.append(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
            locked {
                acceptingAudio = true
            }
        } catch {
            inputNode.removeTap(onBus: 0)
            throw AppError.recordingStartFailed
        }
    }

    func pause() {
        locked {
            acceptingAudio = false
        }
        engine.pause()
    }

    func resume() throws {
        engine.prepare()
        do {
            try engine.start()
            locked {
                acceptingAudio = true
            }
        } catch {
            throw AppError.recordingStoppedUnexpectedly
        }
    }

    @discardableResult
    func stop() -> [Float] {
        locked {
            acceptingAudio = false
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        return snapshotSamples()
    }

    func snapshotSamples() -> [Float] {
        locked { samples }
    }

    private func append(_ buffer: AVAudioPCMBuffer) {
        guard locked({ acceptingAudio }) else { return }
        guard let converted = Self.convertToWhisperSamples(buffer) else { return }
        locked {
            guard acceptingAudio else { return }
            samples.append(contentsOf: converted)
        }
    }

    private static func convertToWhisperSamples(_ buffer: AVAudioPCMBuffer) -> [Float]? {
        guard buffer.frameLength > 0 else { return [] }

        let format = buffer.format
        if format.commonFormat == .pcmFormatFloat32,
           format.sampleRate == Double(WhisperKit.sampleRate),
           format.channelCount == 1,
           !format.isInterleaved,
           let channel = buffer.floatChannelData?[0] {
            return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        }

        let sourceBuffer = Self.downmixedMonoBuffer(from: buffer) ?? buffer
        let sourceFormat = sourceBuffer.format

        if sourceFormat.commonFormat == .pcmFormatFloat32,
           sourceFormat.sampleRate == Double(WhisperKit.sampleRate),
           sourceFormat.channelCount == 1,
           !sourceFormat.isInterleaved,
           let channel = sourceBuffer.floatChannelData?[0] {
            return Array(UnsafeBufferPointer(start: channel, count: Int(sourceBuffer.frameLength)))
        }

        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(WhisperKit.sampleRate),
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: sourceFormat, to: outputFormat) else {
            return nil
        }

        let ratio = outputFormat.sampleRate / max(sourceFormat.sampleRate, 1)
        let frameCapacity = AVAudioFrameCount(max(1, Int(Double(sourceBuffer.frameLength) * ratio) + 512))
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: frameCapacity) else {
            return nil
        }

        var didProvideInput = false
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            if didProvideInput {
                outStatus.pointee = .noDataNow
                return nil
            }
            didProvideInput = true
            outStatus.pointee = .haveData
            return sourceBuffer
        }

        guard conversionError == nil else { return nil }
        switch status {
        case .haveData, .inputRanDry, .endOfStream:
            break
        case .error:
            return nil
        @unknown default:
            return nil
        }

        guard outputBuffer.frameLength > 0, let channel = outputBuffer.floatChannelData?[0] else {
            return []
        }
        return Array(UnsafeBufferPointer(start: channel, count: Int(outputBuffer.frameLength)))
    }

    private static func downmixedMonoBuffer(from buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let format = buffer.format
        guard format.commonFormat == .pcmFormatFloat32,
              format.channelCount > 1,
              !format.isInterleaved,
              let sourceChannels = buffer.floatChannelData,
              let monoFormat = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32,
                  sampleRate: format.sampleRate,
                  channels: 1,
                  interleaved: false
              ),
              let monoBuffer = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: buffer.frameLength),
              let monoChannel = monoBuffer.floatChannelData?[0] else {
            return nil
        }

        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(format.channelCount)
        guard frameCount > 0 else { return monoBuffer }

        monoBuffer.frameLength = buffer.frameLength
        let scale = 1 / Float(channelCount)
        for frame in 0..<frameCount {
            var mixed: Float = 0
            for channelIndex in 0..<channelCount {
                mixed += sourceChannels[channelIndex][frame]
            }
            monoChannel[frame] = mixed * scale
        }
        return monoBuffer
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
