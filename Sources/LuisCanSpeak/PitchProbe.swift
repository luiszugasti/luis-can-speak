import AVFoundation
import Foundation

/// Finds out whether a voice really changes pitch. Some voices ignore
/// AVSpeechUtterance.pitchMultiplier, so the app renders a short phrase at a
/// low and a high pitch (to memory, not the speakers) and compares them.
@MainActor
enum PitchProbe {
    /// Saved between launches, keyed by voice identifier.
    private static var cache: [String: Bool] {
        get { UserDefaults.standard.dictionary(forKey: "pitchSupport") as? [String: Bool] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "pitchSupport") }
    }
    private static var synths: [AVSpeechSynthesizer] = []

    /// nil until the voice has been tested.
    static func cached(_ voice: AVSpeechSynthesisVoice) -> Bool? { cache[voice.identifier] }

    static func supportsPitch(_ voice: AVSpeechSynthesisVoice) async -> Bool {
        if let known = cache[voice.identifier] { return known }
        let low = await medianPitch(voice, multiplier: 0.5)
        let high = await medianPitch(voice, multiplier: 2.0)
        Self.debugLog("\(voice.identifier) 0.5x=\(Int(low)) Hz 2x=\(Int(high)) Hz")
        NSLog("LuisCanSpeak: pitch probe \(voice.identifier): 0.5x=\(Int(low)) Hz, 2x=\(Int(high)) Hz")
        // A real change makes the high one about 4 times the low one.
        // macOS doesn't hand over Personal Voice audio (it renders 0 samples),
        // so a Personal Voice can't be measured. It ignores pitch when you
        // listen to it, so count it as not supported. For any other voice
        // that fails to measure, assume it works.
        let supported: Bool
        if low == 0 || high == 0 {
            supported = !voice.voiceTraits.contains(.isPersonalVoice)
        } else {
            supported = high / low > 1.5
        }
        cache[voice.identifier] = supported
        return supported
    }

    /// Renders a phrase and returns its median pitch in Hz, or 0 if it can't tell.
    static func medianPitch(_ voice: AVSpeechSynthesisVoice, multiplier: Float) async -> Double {
        let utterance = AVSpeechUtterance(string: "Hello there, this is a short pitch test of the voice.")
        utterance.voice = voice
        utterance.pitchMultiplier = multiplier
        let synth = AVSpeechSynthesizer()
        synths.append(synth)
        defer { synths.removeAll { $0 === synth } }

        let (samples, rate) = await withCheckedContinuation { (cont: CheckedContinuation<([Float], Double), Never>) in
            var samples: [Float] = []
            var rate = 22_050.0
            var finished = false
            let lock = NSLock()
            // Some voices never send the empty buffer that marks the end, so
            // stop listening after a few seconds and use what arrived.
            func end() {
                lock.lock()
                defer { lock.unlock() }
                guard !finished else { return }
                finished = true
                cont.resume(returning: (samples, rate))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { end() }
            synth.write(utterance) { buffer in
                guard !finished, let pcm = buffer as? AVAudioPCMBuffer else { return }
                if pcm.frameLength == 0 {
                    end()
                    return
                }
                rate = pcm.format.sampleRate
                let n = Int(pcm.frameLength)
                if let f = pcm.floatChannelData {
                    samples += UnsafeBufferPointer(start: f[0], count: n)
                } else if let i = pcm.int16ChannelData {
                    samples += UnsafeBufferPointer(start: i[0], count: n).map { Float($0) / 32_768 }
                }
            }
        }
        debugLog("\(voice.identifier) at \(multiplier)x: \(samples.count) samples at \(Int(rate)) Hz")
        return estimate(samples, rate: rate)
    }

    /// Appends a line to pitch-probe.log next to the custom words file.
    static func debugLog(_ line: String) {
        let url = CustomWords.fileURL.deletingLastPathComponent().appendingPathComponent("pitch-probe.log")
        let text = "\(Date()) \(line)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// Autocorrelation pitch per 40 ms frame, median over the voiced frames.
    private nonisolated static func estimate(_ samples: [Float], rate: Double) -> Double {
        let frame = Int(rate * 0.04)
        let minLag = Int(rate / 500), maxLag = Int(rate / 60)
        guard frame > maxLag else { return 0 }
        var pitches: [Double] = []
        var start = 0
        while start + frame <= samples.count {
            let w = samples[start..<(start + frame)]
            let energy = w.reduce(0) { $0 + $1 * $1 }
            if energy / Float(frame) > 1e-4 {
                var bestLag = 0
                var best: Float = 0
                for lag in minLag...maxLag {
                    var sum: Float = 0
                    for k in start..<(start + frame - lag) { sum += samples[k] * samples[k + lag] }
                    if sum > best { best = sum; bestLag = lag }
                }
                if best / energy > 0.5, bestLag > 0 { pitches.append(rate / Double(bestLag)) }
            }
            start += frame
        }
        guard !pitches.isEmpty else { return 0 }
        pitches.sort()
        return pitches[pitches.count / 2]
    }
}
