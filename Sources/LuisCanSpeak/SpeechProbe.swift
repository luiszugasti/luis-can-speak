import AVFoundation
import Foundation

/// Speaks lines silently and reports how far into each one the voice got.
/// Used to find text that makes a voice stop early, without anyone listening.
@MainActor
final class SpeechProbe: NSObject, AVSpeechSynthesizerDelegate {
    private let synth = AVSpeechSynthesizer()
    private var reached = 0
    private var done: CheckedContinuation<Void, Never>?

    static func run(_ lines: [String]) async -> String {
        let status = await withCheckedContinuation { cont in
            AVSpeechSynthesizer.requestPersonalVoiceAuthorization { cont.resume(returning: $0) }
        }
        let saved = UserDefaults.standard.string(forKey: "voiceIdentifier")
        let voice = AVSpeechSynthesisVoice.speechVoices().first { $0.identifier == saved }
        var report = "personal voice status \(status.rawValue), voice \(voice?.identifier ?? "none")\n"
        let probe = SpeechProbe()
        for line in lines {
            for (name, v) in [("personal", voice), ("samantha", AVSpeechSynthesisVoice(identifier: "com.apple.voice.compact.en-US.Samantha"))] {
                let started = Date()
                let (reached, length) = await probe.measure(line, voice: v)
                let ok = reached >= length - 2
                report += String(format: "%@ %@ %.1fs %d/%d: %@\n", ok ? "OK  " : "STOP", name, Date().timeIntervalSince(started), reached, length, line)
            }
        }
        return report
    }

    func measure(_ text: String, voice: AVSpeechSynthesisVoice?) async -> (Int, Int) {
        synth.delegate = self
        reached = 0
        let u = AVSpeechUtterance(string: text)
        u.voice = voice
        u.volume = 0.001
        await withCheckedContinuation { cont in
            done = cont
            synth.speak(u)
        }
        return (reached, (text as NSString).length)
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, willSpeakRangeOfSpeechString r: NSRange, utterance: AVSpeechUtterance) {
        MainActor.assumeIsolated { reached = max(reached, r.location + r.length) }
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        MainActor.assumeIsolated { done?.resume(); done = nil }
    }
}
