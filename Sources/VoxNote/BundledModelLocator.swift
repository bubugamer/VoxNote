import Foundation

enum BundledModelLocator {
    private static let bundledRootName = "BundledModels"

    static func whisperModelURL(variant: String) -> URL? {
        let url = bundledModelsRoot()
            .appendingPathComponent("Whisper", isDirectory: true)
            .appendingPathComponent(variant, isDirectory: true)
        return directoryExists(url) ? url : nil
    }

    static func speakerKitURL() -> URL? {
        let url = bundledModelsRoot()
            .appendingPathComponent("SpeakerKit", isDirectory: true)
        return directoryExists(url) ? url : nil
    }

    static var hasAnyBundledModel: Bool {
        directoryExists(bundledModelsRoot())
    }

    private static func bundledModelsRoot() -> URL {
        if let resourceURL = Bundle.main.resourceURL {
            return resourceURL.appendingPathComponent(bundledRootName, isDirectory: true)
        }
        return URL(fileURLWithPath: "Resources")
            .appendingPathComponent(bundledRootName, isDirectory: true)
    }

    private static func directoryExists(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
