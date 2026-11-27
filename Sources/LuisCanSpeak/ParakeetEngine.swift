import AVFoundation
import FluidAudio
import Foundation

/// Speech-to-text with NVIDIA's Parakeet model (the "Ultra" version), run on
/// the Neural Engine through FluidAudio. It hears English, Spanish and 23
/// other European languages without a language setting. It transcribes after
/// you stop talking, so it doesn't show words as you speak.
@MainActor
final class ParakeetEngine {
    enum State: Equatable {
        case notLoaded
        case loading(Double)  // download progress, 0 to 1
        case ready
        case failed(String)
    }

    static let shared = ParakeetEngine()

    private(set) var state: State = .notLoaded
    private var manager: AsrManager?
    private var loadTask: Task<AsrManager, Error>?

    var menuStatus: String {
        switch state {
        case .notLoaded: return "Parakeet: not downloaded yet (about 600 MB)"
        case let .loading(p): return p > 0 ? "Parakeet: downloading \(Int(p * 100))%…" : "Parakeet: loading…"
        case .ready: return "Parakeet: ready"
        case let .failed(message): return "Parakeet failed: \(message)"
        }
    }

    /// Downloads the model the first time, then loads it into memory.
    @discardableResult
    func load() async throws -> AsrManager {
        if let manager { return manager }
        if let loadTask { return try await loadTask.value }

        state = .loading(0)
        let task = Task { () throws -> AsrManager in
            let models = try await AsrModels.downloadAndLoad(version: .ultra) { progress in
                let fraction = progress.fractionCompleted
                Task { @MainActor in
                    if case .loading = ParakeetEngine.shared.state {
                        ParakeetEngine.shared.state = .loading(fraction)
                    }
                }
            }
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            return manager
        }
        loadTask = task
        do {
            let manager = try await task.value
            self.manager = manager
            state = .ready
            loadTask = nil
            return manager
        } catch {
            state = .failed(error.localizedDescription)
            loadTask = nil
            throw error
        }
    }

    /// Turns 16 kHz mono samples into text.
    func transcribe(_ samples: [Float]) async throws -> String {
        // Parakeet needs at least one second of audio. Pad short clips with silence.
        var samples = samples
        if samples.count < 16_000 { samples += [Float](repeating: 0, count: 16_000 - samples.count) }
        let manager = try await load()
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(samples, decoderState: &state)
        return result.text
    }
}
