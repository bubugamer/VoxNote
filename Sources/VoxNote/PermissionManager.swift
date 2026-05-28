import AVFoundation
import AVFAudio
import Foundation

final class PermissionManager {
    static let shared = PermissionManager()

    private init() {}

    func ensureMicrophoneAccess() async throws {
        if #available(macOS 14, *) {
            switch AVAudioApplication.shared.recordPermission {
            case .granted:
                return
            case .denied:
                throw AppError.microphoneDenied
            case .undetermined:
                let granted = try await Self.withPermissionTimeout {
                    await AVAudioApplication.requestRecordPermission()
                }
                if !granted {
                    throw AppError.microphoneDenied
                }
                return
            @unknown default:
                throw AppError.microphoneDenied
            }
        }

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            let granted = try await Self.withPermissionTimeout {
                await AVCaptureDevice.requestAccess(for: .audio)
            }
            if !granted {
                throw AppError.microphoneDenied
            }
        case .denied, .restricted:
            throw AppError.microphoneDenied
        @unknown default:
            throw AppError.microphoneDenied
        }
    }

    private static func withPermissionTimeout(
        _ operation: @escaping @Sendable () async -> Bool
    ) async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            let box = PermissionContinuationBox(continuation)

            Task {
                let granted = await operation()
                box.complete(.success(granted))
            }

            Task {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                box.complete(.failure(AppError.microphonePermissionTimedOut))
            }
        }
    }
}

private final class PermissionContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Error>?

    init(_ continuation: CheckedContinuation<Bool, Error>) {
        self.continuation = continuation
    }

    func complete(_ result: Result<Bool, Error>) {
        let pending: CheckedContinuation<Bool, Error>?
        lock.lock()
        pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }
}
