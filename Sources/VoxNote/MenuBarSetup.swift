import Cocoa

@MainActor
final class MenuBarSetup: NSObject, NSMenuDelegate {
    private weak var target: AppDelegate?
    private var languageItems: [NSMenuItem] = []
    private var modelItems: [NSMenuItem] = []
    private var speakerItem: NSMenuItem?
    private var llmEnabledItem: NSMenuItem?

    init(target: AppDelegate) {
        self.target = target
        super.init()
        buildMenu()
        refresh()
    }

    func refresh() {
        let currentLanguage = LanguageManager.shared.currentSelection
        for item in languageItems {
            item.state = (item.representedObject as? String) == currentLanguage ? .on : .off
        }

        let currentModel = AppModelManager.shared.currentModelVariant
        let modelState = AppModelManager.shared.whisperModelState.displayText
        for item in modelItems {
            guard let variant = item.representedObject as? String,
                  let model = AppModelManager.shared.availableModels.first(where: { $0.variant == variant }) else {
                continue
            }
            let suffix = model.isRecommended ? " (Recommended)" : ""
            item.title = model.displayName + suffix + (variant == currentModel ? " - \(modelState)" : "")
            item.state = variant == currentModel ? .on : .off
        }

        speakerItem?.state = UserDefaults.standard.bool(forKey: "speakerDiarizationEnabled") ? .on : .off
        llmEnabledItem?.state = LLMService.shared.isEnabled ? .on : .off
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        refresh()
    }

    private func buildMenu() {
        let mainMenu = NSMenu(title: "VoxNote")
        NSApp.mainMenu = mainMenu

        buildApplicationMenu(in: mainMenu)
        buildFileMenu(in: mainMenu)
        buildEditMenu(in: mainMenu)
        buildSettingsMenu(in: mainMenu)
        buildHelpMenu(in: mainMenu)
    }

    private func buildApplicationMenu(in mainMenu: NSMenu) {
        let item = NSMenuItem()
        let menu = NSMenu(title: "VoxNote")
        item.submenu = menu
        mainMenu.addItem(item)

        menu.addItem(withTitle: "About VoxNote", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Settings...", action: #selector(AppDelegate.showLLMSettings), keyEquivalent: ","))
        menu.items.last?.target = target
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit VoxNote", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
    }

    private func buildFileMenu(in mainMenu: NSMenu) {
        let item = NSMenuItem()
        let menu = NSMenu(title: "File")
        item.submenu = menu
        mainMenu.addItem(item)

        let open = NSMenuItem(title: "Open Audio/Video...", action: #selector(AppDelegate.openAudioVideo), keyEquivalent: "o")
        open.target = target
        menu.addItem(open)

        let export = NSMenuItem(title: "Export Transcription as TXT...", action: #selector(AppDelegate.exportTranscription), keyEquivalent: "e")
        export.target = target
        menu.addItem(export)

        let exportMarkdown = NSMenuItem(title: "Export Transcription as Markdown...", action: #selector(AppDelegate.exportMarkdown), keyEquivalent: "E")
        exportMarkdown.target = target
        menu.addItem(exportMarkdown)
    }

    private func buildEditMenu(in mainMenu: NSMenu) {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Edit")
        item.submenu = menu
        mainMenu.addItem(item)

        let copy = NSMenuItem(title: "Copy All", action: #selector(AppDelegate.copyAll), keyEquivalent: "c")
        copy.target = target
        menu.addItem(copy)

        let selectAll = NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        menu.addItem(selectAll)
    }

    private func buildSettingsMenu(in mainMenu: NSMenu) {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Settings")
        menu.delegate = self
        item.submenu = menu
        mainMenu.addItem(item)

        let languageItem = NSMenuItem(title: "Language", action: nil, keyEquivalent: "")
        let languageMenu = NSMenu(title: "Language")
        for language in LanguageManager.supportedLanguages {
            let langItem = NSMenuItem(title: language.display, action: #selector(AppDelegate.selectLanguage(_:)), keyEquivalent: "")
            langItem.target = target
            langItem.representedObject = language.code
            languageMenu.addItem(langItem)
            languageItems.append(langItem)
        }
        languageItem.submenu = languageMenu
        menu.addItem(languageItem)

        let modelItem = NSMenuItem(title: "Model", action: nil, keyEquivalent: "")
        let modelMenu = NSMenu(title: "Model")
        modelMenu.delegate = self
        for model in AppModelManager.shared.availableModels {
            let modelMenuItem = NSMenuItem(title: model.displayName, action: #selector(AppDelegate.selectModel(_:)), keyEquivalent: "")
            modelMenuItem.target = target
            modelMenuItem.representedObject = model.variant
            modelMenu.addItem(modelMenuItem)
            modelItems.append(modelMenuItem)
        }
        modelMenu.addItem(.separator())
        let downloadAll = NSMenuItem(title: "Download All Models", action: #selector(AppDelegate.downloadAllModels), keyEquivalent: "")
        downloadAll.target = target
        modelMenu.addItem(downloadAll)
        modelItem.submenu = modelMenu
        menu.addItem(modelItem)

        menu.addItem(.separator())
        let speaker = NSMenuItem(title: "Speaker Diarization", action: #selector(AppDelegate.toggleSpeakerDiarization(_:)), keyEquivalent: "")
        speaker.target = target
        speakerItem = speaker
        menu.addItem(speaker)
        menu.addItem(.separator())

        let llmItem = NSMenuItem(title: "LLM Refinement", action: nil, keyEquivalent: "")
        let llmMenu = NSMenu(title: "LLM Refinement")
        let enabled = NSMenuItem(title: "Enable Refinement", action: #selector(AppDelegate.toggleLLMEnabled(_:)), keyEquivalent: "")
        enabled.target = target
        llmEnabledItem = enabled
        llmMenu.addItem(enabled)
        llmMenu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings...", action: #selector(AppDelegate.showLLMSettings), keyEquivalent: "")
        settings.target = target
        llmMenu.addItem(settings)
        llmItem.submenu = llmMenu
        menu.addItem(llmItem)
    }

    private func buildHelpMenu(in mainMenu: NSMenu) {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Help")
        item.submenu = menu
        mainMenu.addItem(item)

        let docs = NSMenuItem(title: "VoxNote Help", action: #selector(AppDelegate.showMainWindow), keyEquivalent: "")
        docs.target = target
        menu.addItem(docs)
    }
}
