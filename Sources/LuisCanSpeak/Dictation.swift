import AVFoundation
import Foundation
import Speech

enum DictationError: LocalizedError {
    case micDenied
    case noAudioFormat
    case localeUnsupported

    var errorDescription: String? {
        switch self {
        case .micDenied: return "Microphone access is off. Turn it on in System Settings > Privacy & Security > Microphone."
        case .noAudioFormat: return "The speech engine didn't offer an audio format."
        case .localeUnsupported: return "On-device speech recognition doesn't support your language setting."
        }
    }
}

/// Records the microphone and turns it into text with Apple's on-device
/// SpeechAnalyzer (macOS 26). Audio never leaves the Mac.
final class Dictation {
    private let engine = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var converter: AVAudioConverter?

    private let lock = NSLock()
    private var finalized = ""
    private var volatile = ""

    /// Called on the main thread with the text so far.
    var onPartial: ((String) -> Void)?

    private(set) var isRecording = false

    static func requestMicAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    /// Downloads the on-device speech model for the current language if the Mac
    /// doesn't have it yet. Safe to call more than once.
    static func prepareModel() async throws {
        let locale = try await Self.locale()
        let module = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try await request.downloadAndInstall()
        }
    }

    /// The languages you can dictate in, as (locale id, menu name).
    static let languages: [(id: String, name: String)] = [
        ("en-US", "English (US)"),
        ("es-US", "Español (Estados Unidos)"),
        ("es-MX", "Español (México)"),
        ("es-ES", "Español (España)"),
    ]

    private static let languageKey = "dictationLanguage"

    /// The language you picked in the menu. English (US) until you pick one.
    static var languageID: String {
        get { UserDefaults.standard.string(forKey: languageKey) ?? "en-US" }
        set { UserDefaults.standard.set(newValue, forKey: languageKey) }
    }

    private static func locale() async throws -> Locale {
        if let l = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: languageID)) { return l }
        if let l = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) { return l }
        throw DictationError.localeUnsupported
    }

    func start() async throws {
        guard await Self.requestMicAccess() else { throw DictationError.micDenied }

        lock.withLock { finalized = ""; volatile = "" }

        let locale = try await Self.locale()
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let context = AnalysisContext()
        context.contextualStrings[.general] = CustomWords.load()
        try await analyzer.setContext(context)
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw DictationError.noAudioFormat
        }
        try await analyzer.prepareToAnalyze(in: analyzerFormat)

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.inputContinuation = continuation
        self.transcriber = transcriber
        self.analyzer = analyzer

        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self else { return }
                    let text = String(result.text.characters)
                    let snapshot: String = self.lock.withLock {
                        if result.isFinal {
                            self.finalized += text
                            self.volatile = ""
                        } else {
                            self.volatile = text
                        }
                        return self.finalized + self.volatile
                    }
                    DispatchQueue.main.async { self.onPartial?(snapshot) }
                }
            } catch {
                NSLog("LuisCanSpeak: transcription ended with error: \(error)")
            }
        }

        try await analyzer.start(inputSequence: stream)

        let input = engine.inputNode
        let micFormat = input.outputFormat(forBus: 0)
        converter = AVAudioConverter(from: micFormat, to: analyzerFormat)

        input.installTap(onBus: 0, bufferSize: 4096, format: micFormat) { [weak self] buffer, _ in
            guard let self, let converted = self.convert(buffer, to: analyzerFormat) else { return }
            self.inputContinuation?.yield(AnalyzerInput(buffer: converted))
        }
        engine.prepare()
        try engine.start()
        isRecording = true
    }

    /// Stops the mic, waits for the final words, and returns the full text.
    func stop() async -> String {
        guard isRecording else { return "" }
        isRecording = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        inputContinuation?.finish()
        inputContinuation = nil

        do {
            try await analyzer?.finalizeAndFinishThroughEndOfInput()
        } catch {
            NSLog("LuisCanSpeak: finalize failed: \(error)")
        }
        await resultsTask?.value
        resultsTask = nil
        analyzer = nil
        transcriber = nil

        return lock.withLock { (finalized + volatile) }
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Throws away the recording without returning text.
    func cancel() async {
        guard isRecording else { return }
        isRecording = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        inputContinuation?.finish()
        inputContinuation = nil
        await analyzer?.cancelAndFinishNow()
        resultsTask?.cancel()
        resultsTask = nil
        analyzer = nil
    }

    private func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        if buffer.format == format { return buffer }
        guard let converter else { return nil }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }

        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        if let error {
            NSLog("LuisCanSpeak: audio convert failed: \(error)")
            return nil
        }
        return out
    }
}
