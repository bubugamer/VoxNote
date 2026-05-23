import Foundation
@preconcurrency import WhisperKit
@preconcurrency import SpeakerKit

final class AppModelManager: @unchecked Sendable {
    static let shared = AppModelManager()

    static let defaultModelVariant = "openai_whisper-large-v3-v20240930_626MB"

    private let defaults = UserDefaults.standard
    private let stateLock = NSLock()
    private var autoUnloadTask: Task<Void, Never>?

    private(set) var whisperKit: WhisperKit?
    private(set) var speakerKit: SpeakerKit?

    private var storedWhisperState: AppModelManagerState = .notDownloaded
    private var storedSpeakerReady = false

    let availableModels: [WhisperModelInfo] = [
        WhisperModelInfo(
            variant: "openai_whisper-large-v3-v20240930_626MB",
            displayName: "large-v3 (626MB)",
            sizeDescription: "626 MB",
            isRecommended: true,
            isMultilingual: true
        ),
        WhisperModelInfo(
            variant: "openai_whisper-small",
            displayName: "small",
            sizeDescription: "~150 MB",
            isRecommended: false,
            isMultilingual: true
        ),
        WhisperModelInfo(
            variant: "openai_whisper-tiny",
            displayName: "tiny",
            sizeDescription: "~40 MB",
            isRecommended: false,
            isMultilingual: true
        )
    ]

    private init() {
        if BundledModelLocator.whisperModelURL(variant: currentModelVariant) != nil {
            storedWhisperState = .downloaded
        }
    }

    var currentModelVariant: String {
        defaults.string(forKey: "selectedModel") ?? Self.defaultModelVariant
    }

    var currentModelInfo: WhisperModelInfo {
        availableModels.first(where: { $0.variant == currentModelVariant }) ?? availableModels[0]
    }

    var whisperModelState: AppModelManagerState {
        stateLock.lock()
        let state = storedWhisperState
        stateLock.unlock()
        return state
    }

    var speakerKitReady: Bool {
        stateLock.lock()
        let ready = storedSpeakerReady
        stateLock.unlock()
        return ready
    }

    func ensureWhisperKitReady(
        variant: String? = nil,
        progressCallback: @escaping @Sendable (AppModelManagerState) -> Void
    ) async throws {
        cancelAutoUnload()
        let selectedVariant = variant ?? currentModelVariant

        if let whisperKit, selectedVariant == currentModelVariant, whisperKit.modelState == .loaded {
            setWhisperState(.ready, callback: progressCallback)
            return
        }

        if whisperKit != nil, selectedVariant != currentModelVariant {
            await unloadWhisperKit()
        }

        defaults.set(selectedVariant, forKey: "selectedModel")

        do {
            let modelFolder: URL
            if let bundledModelFolder = BundledModelLocator.whisperModelURL(variant: selectedVariant) {
                modelFolder = bundledModelFolder
                setWhisperState(.downloaded, callback: progressCallback)
            } else {
                setWhisperState(.downloading(progress: 0), callback: progressCallback)
                modelFolder = try await WhisperKit.download(variant: selectedVariant) { progress in
                    let fraction = min(1, max(0, progress.fractionCompleted))
                    self.setWhisperState(.downloading(progress: fraction), callback: progressCallback)
                }
                setWhisperState(.downloaded, callback: progressCallback)
            }

            setWhisperState(.loading, callback: progressCallback)

            let config = WhisperKitConfig(
                model: selectedVariant,
                modelFolder: modelFolder.path,
                tokenizerFolder: modelFolder,
                verbose: false,
                prewarm: true,
                load: false,
                download: false
            )
            let kit = try await WhisperKit(config)
            kit.modelStateCallback = { _, newState in
                switch newState {
                case .loaded:
                    self.setWhisperState(.ready, callback: progressCallback)
                case .loading, .prewarming:
                    self.setWhisperState(.loading, callback: progressCallback)
                case .downloaded, .prewarmed:
                    self.setWhisperState(.downloaded, callback: progressCallback)
                case .downloading:
                    self.setWhisperState(.downloading(progress: 0), callback: progressCallback)
                case .unloaded, .unloading:
                    self.setWhisperState(.notDownloaded, callback: progressCallback)
                }
            }
            try await kit.loadModels()
            whisperKit = kit
            setWhisperState(.ready, callback: progressCallback)
        } catch {
            setWhisperState(.error(error.localizedDescription), callback: progressCallback)
            throw error
        }
    }

    func switchModel(to variant: String) async throws {
        guard variant != currentModelVariant || whisperModelState != .ready else { return }
        await unloadWhisperKit()
        defaults.set(variant, forKey: "selectedModel")
        NotificationCenter.default.post(name: .settingsDidChange, object: self)
        try await ensureWhisperKitReady(variant: variant) { _ in }
    }

    func unloadWhisperKit() async {
        autoUnloadTask?.cancel()
        autoUnloadTask = nil
        if let whisperKit {
            await whisperKit.unloadModels()
        }
        whisperKit = nil
        let state: AppModelManagerState = BundledModelLocator.whisperModelURL(variant: currentModelVariant) == nil ? .notDownloaded : .downloaded
        setWhisperState(state, callback: nil)
    }

    func ensureSpeakerKitReady(
        progressCallback: @escaping @Sendable (Double) -> Void
    ) async throws {
        if speakerKit != nil, speakerKitReady {
            progressCallback(1)
            return
        }

        let config: PyannoteConfig
        if let bundledSpeakerKitURL = BundledModelLocator.speakerKitURL() {
            config = PyannoteConfig(modelFolder: bundledSpeakerKitURL.path, download: false, load: false, verbose: false)
        } else {
            config = PyannoteConfig(download: true, load: false, verbose: false)
        }
        let kit = try await SpeakerKit(config)
        progressCallback(0.1)
        try await kit.ensureModelsLoaded()

        speakerKit = kit
        setSpeakerReady(true)
        progressCallback(1)
    }

    func unloadSpeakerKit() async {
        if let speakerKit {
            await speakerKit.unloadModels()
        }
        speakerKit = nil
        setSpeakerReady(false)
    }

    func scheduleAutoUnload(after seconds: TimeInterval) {
        autoUnloadTask?.cancel()
        autoUnloadTask = Task { [weak self] in
            let nanos = UInt64(max(1, seconds) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanos)
            guard !Task.isCancelled else { return }
            await self?.unloadWhisperKit()
        }
    }

    func cancelAutoUnload() {
        autoUnloadTask?.cancel()
        autoUnloadTask = nil
    }

    private func setWhisperState(
        _ state: AppModelManagerState,
        callback: (@Sendable (AppModelManagerState) -> Void)?
    ) {
        stateLock.lock()
        storedWhisperState = state
        stateLock.unlock()
        callback?(state)
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .modelStateDidChange, object: self)
        }
    }

    private func setSpeakerReady(_ ready: Bool) {
        stateLock.lock()
        storedSpeakerReady = ready
        stateLock.unlock()
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .modelStateDidChange, object: self)
        }
    }
}
