import AVFoundation
import Foundation

/// Reads text aloud. Uses your Personal Voice when macOS lets the app use it,
/// and falls back to the system voice otherwise.
final class Speaker: NSObject, AVSpeechSynthesizerDelegate {
    private let synth = AVSpeechSynthesizer()
    private var voice: AVSpeechSynthesisVoice?
    private var pendingUtterances = 0

    /// Called on the main thread when everything queued has finished or was stopped.
    var onFinished: (() -> Void)?

    var isSpeaking: Bool { pendingUtterances > 0 }

    var voiceDescription: String {
        guard let voice else { return "System voice" }
        return voice.voiceTraits.contains(.isPersonalVoice) ? "Personal Voice (\(voice.name))" : voice.name
    }

    override init() {
        super.init()
        synth.delegate = self
    }

    /// Asks macOS for Personal Voice access, then picks the voice.
    func setUp(completion: @escaping () -> Void) {
        AVSpeechSynthesizer.requestPersonalVoiceAuthorization { [weak self] status in
            DispatchQueue.main.async {
                guard let self else { return }
                if status == .authorized {
                    self.voice = AVSpeechSynthesisVoice.speechVoices()
                        .first { $0.voiceTraits.contains(.isPersonalVoice) }
                }
                if self.voice == nil {
                    self.voice = AVSpeechSynthesisVoice(language: Locale.current.identifier.replacingOccurrences(of: "_", with: "-"))
                }
                completion()
            }
        }
    }

    func speak(_ text: String) {
        let clean = Self.speakable(text)
        guard !clean.isEmpty else { return }
        let utterance = AVSpeechUtterance(string: clean)
        utterance.voice = voice
        pendingUtterances += 1
        synth.speak(utterance)
    }

    func stop() {
        guard isSpeaking else { return }
        synth.stopSpeaking(at: .immediate)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { self.utteranceEnded() }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { self.utteranceEnded() }
    }

    private func utteranceEnded() {
        pendingUtterances = max(0, pendingUtterances - 1)
        if pendingUtterances == 0 { onFinished?() }
    }

    /// Strips Markdown symbols so the voice doesn't read "asterisk asterisk".
    /// Keeps every word of the reply, including code.
    static func speakable(_ markdown: String) -> String {
        var lines: [String] = []
        for raw in markdown.components(separatedBy: .newlines) {
            var line = raw
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") { continue }
            if trimmed.range(of: #"^\|?[\s:\-|]+\|?$"#, options: .regularExpression) != nil, trimmed.contains("-") { continue }
            line = line.replacingOccurrences(of: #"^\s{0,3}#{1,6}\s+"#, with: "", options: .regularExpression)
            line = line.replacingOccurrences(of: #"^\s*>\s?"#, with: "", options: .regularExpression)
            line = line.replacingOccurrences(of: #"^\s*[-*+]\s+"#, with: "", options: .regularExpression)
            line = line.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
            line = line.replacingOccurrences(of: "**", with: "")
            line = line.replacingOccurrences(of: "__", with: "")
            line = line.replacingOccurrences(of: "`", with: "")
            line = line.replacingOccurrences(of: "|", with: ", ")
            lines.append(line)
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
