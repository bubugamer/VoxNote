import AVFoundation
import Foundation

final class VideoAudioExtractor {
    static let supportedVideoExtensions: Set<String> = ["mp4", "mov", "mkv", "avi", "webm"]
    static let supportedAudioExtensions: Set<String> = ["mp3", "wav", "m4a", "caf", "aac", "flac", "aiff", "aif"]

    static func isVideoFile(_ url: URL) -> Bool {
        supportedVideoExtensions.contains(url.pathExtension.lowercased())
    }

    static func isSupportedFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return supportedVideoExtensions.contains(ext) || supportedAudioExtensions.contains(ext)
    }

    func extractAudio(from videoURL: URL) async throws -> URL {
        let asset = AVURLAsset(url: videoURL)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard !audioTracks.isEmpty else {
            throw AppError.noAudioTrack
        }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoxNote-\(UUID().uuidString)")
            .appendingPathExtension("m4a")

        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw AppError.exportSessionUnavailable
        }

        exportSession.outputURL = tempURL
        exportSession.outputFileType = .m4a
        exportSession.shouldOptimizeForNetworkUse = false

        await withCheckedContinuation { continuation in
            exportSession.exportAsynchronously {
                continuation.resume()
            }
        }

        switch exportSession.status {
        case .completed:
            return tempURL
        case .failed:
            throw AppError.exportFailed(exportSession.error?.localizedDescription ?? "Audio extraction failed.")
        case .cancelled:
            throw CancellationError()
        default:
            throw AppError.exportFailed("Audio extraction did not complete.")
        }
    }

    func cleanup(tempURL: URL) {
        try? FileManager.default.removeItem(at: tempURL)
    }
}
