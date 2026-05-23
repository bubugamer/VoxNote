import Foundation
@preconcurrency import SpeakerKit
@preconcurrency import WhisperKit

@main
struct ModelBundler {
    static func main() async throws {
        let options = try Options.parse(CommandLine.arguments.dropFirst())
        let outputURL = URL(fileURLWithPath: options.outputPath).standardizedFileURL

        try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

        if !options.skipWhisper {
            try await prepareWhisperModel(variant: options.whisperVariant, outputURL: outputURL)
        }

        if !options.skipSpeaker {
            try await prepareSpeakerKit(outputURL: outputURL)
        }

        print("Bundled models are ready at \(outputURL.path)")
    }

    private static func prepareWhisperModel(variant: String, outputURL: URL) async throws {
        print("Downloading Whisper model: \(variant)")
        let downloadedURL = try await WhisperKit.download(variant: variant) { progress in
            printProgress("Whisper", progress.fractionCompleted)
        }
        print("")

        let destination = outputURL
            .appendingPathComponent("Whisper", isDirectory: true)
            .appendingPathComponent(variant, isDirectory: true)
        try replaceDirectory(source: downloadedURL, destination: destination)

        if let tokenizerVariant = tokenizerVariant(for: variant) {
            print("Downloading Whisper tokenizer for \(tokenizerVariant.description)")
            _ = try await ModelUtilities.loadTokenizer(for: tokenizerVariant, tokenizerFolder: destination)
        } else {
            print("Warning: unknown tokenizer variant for \(variant); tokenizer may be downloaded on first run.")
        }
    }

    private static func prepareSpeakerKit(outputURL: URL) async throws {
        print("Downloading SpeakerKit models")
        let stagingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoxNoteSpeakerKit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stagingURL) }

        let config = PyannoteConfig(downloadBase: stagingURL.path, download: true, load: false, verbose: false)
        let kit = try await SpeakerKit(config)
        guard let diarizer = kit.diarizer as? SpeakerKitDiarizer,
              let modelPath = diarizer.modelPath else {
            throw BundlerError.speakerKitPathUnavailable
        }

        let destination = outputURL.appendingPathComponent("SpeakerKit", isDirectory: true)
        try replaceDirectory(source: modelPath, destination: destination)
    }

    private static func tokenizerVariant(for variant: String) -> ModelVariant? {
        if variant.contains("large-v3") { return .largev3 }
        if variant.contains("large-v2") { return .largev2 }
        if variant.contains("large") { return .large }
        if variant.contains("medium.en") { return .mediumEn }
        if variant.contains("medium") { return .medium }
        if variant.contains("small.en") { return .smallEn }
        if variant.contains("small") { return .small }
        if variant.contains("base.en") { return .baseEn }
        if variant.contains("base") { return .base }
        if variant.contains("tiny.en") { return .tinyEn }
        if variant.contains("tiny") { return .tiny }
        return nil
    }

    private static func replaceDirectory(source: URL, destination: URL) throws {
        let parent = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: source, to: destination)
        print("Copied \(source.path) -> \(destination.path)")
    }

    private static func printProgress(_ label: String, _ fraction: Double) {
        let percent = Int(min(1, max(0, fraction)) * 100)
        print("\r\(label): \(percent)%", terminator: "")
        fflush(stdout)
    }
}

private struct Options {
    let outputPath: String
    let whisperVariant: String
    let skipWhisper: Bool
    let skipSpeaker: Bool

    static func parse(_ args: ArraySlice<String>) throws -> Options {
        var outputPath = "Resources/BundledModels"
        var whisperVariant = "openai_whisper-large-v3-v20240930_626MB"
        var skipWhisper = false
        var skipSpeaker = false

        var iterator = args.makeIterator()
        while let arg = iterator.next() {
            switch arg {
            case "--output":
                guard let value = iterator.next() else { throw BundlerError.missingValue(arg) }
                outputPath = value
            case "--whisper":
                guard let value = iterator.next() else { throw BundlerError.missingValue(arg) }
                whisperVariant = value
            case "--skip-whisper":
                skipWhisper = true
            case "--skip-speaker":
                skipSpeaker = true
            case "--help", "-h":
                printHelp()
                Foundation.exit(0)
            default:
                throw BundlerError.unknownArgument(arg)
            }
        }

        return Options(
            outputPath: outputPath,
            whisperVariant: whisperVariant,
            skipWhisper: skipWhisper,
            skipSpeaker: skipSpeaker
        )
    }

    private static func printHelp() {
        print("""
        Usage:
          swift run -c release ModelBundler [options]

        Options:
          --output PATH       Destination directory. Default: Resources/BundledModels
          --whisper VARIANT   WhisperKit model variant. Default: openai_whisper-large-v3-v20240930_626MB
          --skip-whisper      Do not prepare Whisper model files
          --skip-speaker      Do not prepare SpeakerKit model files
        """)
    }
}

private enum BundlerError: LocalizedError {
    case missingValue(String)
    case unknownArgument(String)
    case speakerKitPathUnavailable

    var errorDescription: String? {
        switch self {
        case .missingValue(let arg):
            return "Missing value for \(arg)."
        case .unknownArgument(let arg):
            return "Unknown argument: \(arg)."
        case .speakerKitPathUnavailable:
            return "SpeakerKit finished downloading, but no model path was reported."
        }
    }
}
