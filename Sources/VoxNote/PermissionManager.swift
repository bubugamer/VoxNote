import AVFoundation
import Foundation

final class PermissionManager {
    static let shared = PermissionManager()

    private init() {}

    func ensureMicrophoneAccess() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            if !granted {
                throw AppError.microphoneDenied
            }
        case .denied, .restricted:
            throw AppError.microphoneDenied
        @unknown default:
            throw AppError.microphoneDenied
        }
    }
}
