import Foundation

enum AudioSignal {
    static func containsNonSilentSamples(_ samples: [Float], threshold: Float = 0.00001) -> Bool {
        samples.contains { sample in
            sample.isFinite && abs(sample) > threshold
        }
    }
}
