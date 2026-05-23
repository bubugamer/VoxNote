import Cocoa

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var mainWindow: MainWindow?
    private var menuBarSetup: MenuBarSetup?
    private var llmSettingsWindow: LLMSettingsWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = MainWindow()
        mainWindow = window
        window.onSettings = { [weak self] in
            self?.showLLMSettings()
        }
        menuBarSetup = MenuBarSetup(target: self)
        TranscriptionOrchestrator.shared.onStateChange = { [weak self] state in
            self?.mainWindow?.update(state: state)
        }

        NotificationCenter.default.addObserver(self, selector: #selector(languageChanged), name: .languageDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged), name: .settingsDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(modelStateChanged), name: .modelStateDidChange, object: nil)

        UserDefaults.standard.set(true, forKey: "hasLaunchedBefore")
        window.show()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        mainWindow?.show()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        TranscriptionOrchestrator.shared.cancel()
    }

    @objc func showMainWindow() {
        mainWindow?.show()
    }

    @objc func openAudioVideo() {
        mainWindow?.show()
        mainWindow?.openFilePanel()
    }

    @objc func exportTranscription() {
        mainWindow?.exportTranscription()
    }

    @objc func exportMarkdown() {
        mainWindow?.exportMarkdown()
    }

    @objc func copyAll() {
        mainWindow?.copyAll()
    }

    @objc func showLLMSettings() {
        if llmSettingsWindow == nil {
            llmSettingsWindow = LLMSettingsWindow()
        }
        llmSettingsWindow?.show()
    }

    @objc func selectLanguage(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String else { return }
        LanguageManager.shared.currentSelection = code
    }

    @objc func selectModel(_ sender: NSMenuItem) {
        guard let variant = sender.representedObject as? String else { return }
        Task {
            do {
                try await AppModelManager.shared.switchModel(to: variant)
            } catch {
                showMenuError(error.localizedDescription)
            }
        }
    }

    @objc func toggleSpeakerDiarization(_ sender: NSMenuItem) {
        let defaults = UserDefaults.standard
        let newValue = !defaults.bool(forKey: "speakerDiarizationEnabled")
        defaults.set(newValue, forKey: "speakerDiarizationEnabled")
        NotificationCenter.default.post(name: .settingsDidChange, object: self)
    }

    @objc func toggleLLMEnabled(_ sender: NSMenuItem) {
        LLMService.shared.isEnabled.toggle()
    }

    @objc func downloadAllModels() {
        Task {
            for model in AppModelManager.shared.availableModels {
                do {
                    try await AppModelManager.shared.ensureWhisperKitReady(variant: model.variant) { _ in }
                    await AppModelManager.shared.unloadWhisperKit()
                } catch {
                    showMenuError(error.localizedDescription)
                    break
                }
            }
        }
    }

    @objc private func languageChanged() {
        mainWindow?.refreshLanguage()
        menuBarSetup?.refresh()
    }

    @objc private func settingsChanged() {
        menuBarSetup?.refresh()
    }

    @objc private func modelStateChanged() {
        mainWindow?.refreshModelStatus()
        menuBarSetup?.refresh()
    }

    private func showMenuError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "VoxNote"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}
