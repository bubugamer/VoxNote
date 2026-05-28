import Foundation
@preconcurrency import WhisperKit

enum VoxTranscriptionState: Equatable {
    case idle
    case extractingAudio
    case downloadingModel(progress: Double)
    case loadingModel
    case preparingAudio
    case transcribing(progress: Double, partialText: String)
    case recording(confirmedText: String, pendingText: String, duration: TimeInterval, isPaused: Bool, modelState: AppModelManagerState)
    case diarizing(progress: Double)
    case refining
    case completed(String)
    case error(String)

    var isBusy: Bool {
        switch self {
        case .idle, .completed, .error:
            return false
        case .extractingAudio, .downloadingModel, .loadingModel, .preparingAudio,
             .transcribing, .recording, .diarizing, .refining:
            return true
        }
    }

    var text: String {
        switch self {
        case .idle:
            return ""
        case .extractingAudio:
            return "Extracting audio..."
        case .downloadingModel(let progress):
            return "Downloading model... \(Int(progress * 100))%"
        case .loadingModel:
            return "Loading model..."
        case .preparingAudio:
            return "Preparing audio..."
        case .transcribing(let progress, _):
            return "Transcribing... \(Int(progress * 100))%"
        case .recording(_, _, let duration, let isPaused, let modelState):
            let prefix = isPaused ? "Paused" : "Recording"
            let suffix: String
            switch modelState {
            case .ready:
                suffix = ""
            case .downloading(let progress):
                suffix = " · Downloading model \(Int(progress * 100))%"
            case .loading, .downloaded, .notDownloaded:
                suffix = " · Loading model..."
            case .error:
                suffix = " · Model unavailable"
            }
            return "\(prefix)... \(Self.formatDuration(duration))\(suffix)"
        case .diarizing(let progress):
            return "Identifying speakers... \(Int(progress * 100))%"
        case .refining:
            return "Refining..."
        case .completed:
            return ""
        case .error(let message):
            return message
        }
    }

    static func formatDuration(_ duration: TimeInterval) -> String {
        let total = max(0, Int(duration.rounded(.down)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

enum AppModelManagerState: Equatable {
    case notDownloaded
    case downloading(progress: Double)
    case downloaded
    case loading
    case ready
    case error(String)

    var displayText: String {
        switch self {
        case .notDownloaded:
            return "Not Downloaded"
        case .downloading(let progress):
            return "Downloading... \(Int(progress * 100))%"
        case .downloaded:
            return "Downloaded"
        case .loading:
            return "Loading"
        case .ready:
            return "Ready"
        case .error(let message):
            return "Error: \(message)"
        }
    }
}

struct WhisperModelInfo: Equatable {
    let variant: String
    let displayName: String
    let sizeDescription: String
    let isRecommended: Bool
    let isMultilingual: Bool
}

struct StreamingState: Equatable {
    var confirmedText: String
    var pendingText: String
    var duration: TimeInterval
    var isRecording: Bool
    var isPaused: Bool
    var modelState: AppModelManagerState
}

struct StreamingResult {
    var finalText: String
    var segments: [TranscriptionSegment]
    var audioArray: [Float]
    var duration: TimeInterval
}

enum AppError: LocalizedError {
    case noWhisperKit
    case noAudioTrack
    case exportSessionUnavailable
    case exportFailed(String)
    case microphoneDenied
    case microphonePermissionTimedOut
    case microphoneUnavailable
    case microphoneInputFormatUnavailable
    case recordingStartFailed
    case recordingStoppedUnexpectedly
    case llmNotConfigured
    case invalidLLMResponse
    case llmTimedOut

    var errorDescription: String? {
        switch self {
        case .noWhisperKit:
            return "Speech model is not ready."
        case .noAudioTrack:
            return "No audio track found in video file."
        case .exportSessionUnavailable:
            return "Could not create an audio export session for this video."
        case .exportFailed(let message):
            return message
        case .microphoneDenied:
            return "Microphone access is required for real-time transcription. Please enable VoxNote in System Settings > Privacy & Security > Microphone."
        case .microphonePermissionTimedOut:
            return "Microphone permission did not complete. Please enable VoxNote in System Settings > Privacy & Security > Microphone, then try recording again."
        case .microphoneUnavailable:
            return "No microphone input device is available. Please connect or select a microphone, then try again."
        case .microphoneInputFormatUnavailable:
            return "VoxNote could not read a usable microphone input format. Please check your microphone device and try again."
        case .recordingStartFailed:
            return "Recording could not start. Please check microphone input and try again."
        case .recordingStoppedUnexpectedly:
            return "Recording stopped unexpectedly. Please check microphone input and try again."
        case .llmNotConfigured:
            return "LLM refinement is enabled, but the API settings are incomplete."
        case .invalidLLMResponse:
            return "The LLM service returned an unexpected response."
        case .llmTimedOut:
            return "The LLM service took too long to respond."
        }
    }
}

extension Notification.Name {
    static let languageDidChange = Notification.Name("VoxNoteLanguageDidChange")
    static let settingsDidChange = Notification.Name("VoxNoteSettingsDidChange")
    static let modelStateDidChange = Notification.Name("VoxNoteModelStateDidChange")
}
