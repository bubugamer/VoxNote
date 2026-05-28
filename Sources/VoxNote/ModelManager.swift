import Foundation
@preconcurrency import WhisperKit
@preconcurrency import SpeakerKit

final class AppModelManager: @unchecked Sendable {
    static let shared = AppModelManager()

    static let legacyDefaultModelVariant = "openai_whisper-large-v3-v20240930_626MB"
    static let defaultModelVariant = "openai_whisper-small"
    private static let defaultModelMigrationKey = "didMigrateDefaultModelToSmall"

    private let defaults = UserDefaults.standard
    private let stateLock = NSLock()
    private var autoUnloadTask: Task<Void, Never>?
    private var whisperLoadTask: Task<Void, Error>?
    private var whisperLoadVariant: String?
    private var whisperStateObservers: [UUID: @Sendable (AppModelManagerState) -> Void] = [:]

    private(set) var whisperKit: WhisperKit?
    private(set) var speakerKit: SpeakerKit?

    private var storedWhisperState: AppModelManagerState = .notDownloaded
    private var storedSpeakerReady = false

    let availableModels: [WhisperModelInfo] = [
        WhisperModelInfo(
            variant: "openai_whisper-small",
            displayName: "small",
            sizeDescription: "~467 MB",
            isRecommended: true,
            isMultilingual: true
        ),
        WhisperModelInfo(
            variant: "openai_whisper-large-v3-v20240930_626MB",
            displayName: "large-v3 (626MB)",
            sizeDescription: "626 MB",
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
        migrateLegacyDefaultModelIfNeeded()
        if BundledModelLocator.whisperModelURL(variant: currentModelVariant) != nil {
            storedWhisperState = .downloaded
        }
    }

    var currentModelVariant: String {
        guard let stored = defaults.string(forKey: "selectedModel"),
              availableModels.contains(where: { $0.variant == stored }) else {
            return Self.defaultModelVariant
        }
        return stored
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

    var canStartRealtimeRecording: Bool {
        whisperModelState == .ready
    }

    func ensureWhisperKitReady(
        variant: String? = nil,
        progressCallback: @escaping @Sendable (AppModelManagerState) -> Void
    ) async throws {
        cancelAutoUnload()
        let selectedVariant = variant ?? currentModelVariant

        if let whisperKit, selectedVariant == currentModelVariant, whisperKit.modelState == .loaded {
            progressCallback(.ready)
            return
        }

        let observerID = registerWhisperStateObserver(progressCallback)
        defer { unregisterWhisperStateObserver(observerID) }

        if let existingTask = existingWhisperLoadTask(for: selectedVariant) {
            progressCallback(whisperModelState)
            try await existingTask.value
            progressCallback(whisperModelState)
            return
        }

        cancelWhisperLoadTaskIfNeeded(for: selectedVariant)

        if whisperKit != nil, selectedVariant != currentModelVariant {
            await unloadWhisperKit()
        }

        defaults.set(selectedVariant, forKey: "selectedModel")

        let loadTask = Task { [self] in
            try await loadWhisperKit(variant: selectedVariant)
        }
        setWhisperLoadTask(loadTask, variant: selectedVariant)

        do {
            try await loadTask.value
            clearWhisperLoadTask(for: selectedVariant)
            progressCallback(whisperModelState)
        } catch {
            clearWhisperLoadTask(for: selectedVariant)
            throw error
        }
    }

    private func loadWhisperKit(variant selectedVariant: String) async throws {
        do {
            let modelFolder: URL
            if let bundledModelFolder = BundledModelLocator.whisperModelURL(variant: selectedVariant) {
                modelFolder = bundledModelFolder
                setWhisperState(.downloaded, callback: nil)
            } else {
                setWhisperState(.downloading(progress: 0), callback: nil)
                modelFolder = try await WhisperKit.download(variant: selectedVariant) { progress in
                    let fraction = min(1, max(0, progress.fractionCompleted))
                    self.setWhisperState(.downloading(progress: fraction), callback: nil)
                }
                setWhisperState(.downloaded, callback: nil)
            }

            setWhisperState(.loading, callback: nil)

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
                    self.setWhisperState(.ready, callback: nil)
                case .loading, .prewarming:
                    self.setWhisperState(.loading, callback: nil)
                case .downloaded, .prewarmed:
                    self.setWhisperState(.downloaded, callback: nil)
                case .downloading:
                    self.setWhisperState(.downloading(progress: 0), callback: nil)
                case .unloaded, .unloading:
                    self.setWhisperState(.notDownloaded, callback: nil)
                }
            }
            try await kit.loadModels()
            whisperKit = kit
            setWhisperState(.ready, callback: nil)
        } catch {
            setWhisperState(.error(error.localizedDescription), callback: nil)
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
        cancelWhisperLoadTask()
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
        autoUnloadTask = nil
    }

    func cancelAutoUnload() {
        autoUnloadTask?.cancel()
        autoUnloadTask = nil
    }

    private func setWhisperState(
        _ state: AppModelManagerState,
        callback: (@Sendable (AppModelManagerState) -> Void)?
    ) {
        let observers: [@Sendable (AppModelManagerState) -> Void]
        stateLock.lock()
        storedWhisperState = state
        observers = Array(whisperStateObservers.values)
        stateLock.unlock()
        callback?(state)
        for observer in observers {
            observer(state)
        }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .modelStateDidChange, object: self)
        }
    }

    private func migrateLegacyDefaultModelIfNeeded() {
        guard !defaults.bool(forKey: Self.defaultModelMigrationKey) else { return }
        if defaults.string(forKey: "selectedModel") == Self.legacyDefaultModelVariant {
            defaults.set(Self.defaultModelVariant, forKey: "selectedModel")
        }
        defaults.set(true, forKey: Self.defaultModelMigrationKey)
    }

    private func registerWhisperStateObserver(
        _ observer: @escaping @Sendable (AppModelManagerState) -> Void
    ) -> UUID {
        let id = UUID()
        stateLock.lock()
        whisperStateObservers[id] = observer
        stateLock.unlock()
        return id
    }

    private func unregisterWhisperStateObserver(_ id: UUID) {
        stateLock.lock()
        whisperStateObservers[id] = nil
        stateLock.unlock()
    }

    private func existingWhisperLoadTask(for variant: String) -> Task<Void, Error>? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard whisperLoadVariant == variant else { return nil }
        return whisperLoadTask
    }

    private func setWhisperLoadTask(_ task: Task<Void, Error>, variant: String) {
        stateLock.lock()
        whisperLoadTask = task
        whisperLoadVariant = variant
        stateLock.unlock()
    }

    private func clearWhisperLoadTask(for variant: String) {
        stateLock.lock()
        if whisperLoadVariant == variant {
            whisperLoadTask = nil
            whisperLoadVariant = nil
        }
        stateLock.unlock()
    }

    private func cancelWhisperLoadTaskIfNeeded(for variant: String) {
        stateLock.lock()
        let task = whisperLoadVariant == nil || whisperLoadVariant == variant ? nil : whisperLoadTask
        if task != nil {
            whisperLoadTask = nil
            whisperLoadVariant = nil
        }
        stateLock.unlock()
        task?.cancel()
    }

    private func cancelWhisperLoadTask() {
        stateLock.lock()
        let task = whisperLoadTask
        whisperLoadTask = nil
        whisperLoadVariant = nil
        stateLock.unlock()
        task?.cancel()
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
