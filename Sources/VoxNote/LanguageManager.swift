import Foundation

final class LanguageManager {
    static let shared = LanguageManager()

    static let supportedLanguages: [(display: String, code: String, bcp47: String?)] = [
        ("Auto Detect", "auto", nil),
        ("English", "en", "en-US"),
        ("简体中文", "zh", "zh-CN"),
        ("日本語", "ja", "ja-JP"),
        ("한국어", "ko", "ko-KR")
    ]

    private let defaults = UserDefaults.standard
    private let key = "selectedLanguage"

    private init() {
        defaults.register(defaults: [
            key: "auto",
            "hasLaunchedBefore": false,
            "selectedModel": AppModelManager.defaultModelVariant,
            "speakerDiarizationEnabled": false,
            "llmEnabled": false,
            "llmBaseURL": "",
            "llmAPIKey": "",
            "llmModel": ""
        ])
    }

    var currentSelection: String {
        get {
            let stored = defaults.string(forKey: key) ?? "auto"
            return Self.supportedLanguages.contains(where: { $0.code == stored }) ? stored : "auto"
        }
        set {
            let code = Self.supportedLanguages.contains(where: { $0.code == newValue }) ? newValue : "auto"
            defaults.set(code, forKey: key)
            NotificationCenter.default.post(name: .languageDidChange, object: self)
        }
    }

    var whisperLanguage: String? {
        currentSelection == "auto" ? nil : currentSelection
    }

    var bcp47Language: String? {
        Self.supportedLanguages.first(where: { $0.code == currentSelection })?.bcp47
    }

    var displayName: String {
        Self.supportedLanguages.first(where: { $0.code == currentSelection })?.display ?? "Auto Detect"
    }
}
