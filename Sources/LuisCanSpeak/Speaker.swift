import AVFoundation
import Foundation
import NaturalLanguage

/// Reads text aloud. Uses your Personal Voice when macOS lets the app use it,
/// and falls back to the system voice otherwise.
final class Speaker: NSObject, AVSpeechSynthesizerDelegate {
    private let synth = AVSpeechSynthesizer()
    private var voice: AVSpeechSynthesisVoice?

    /// Called on the main thread when everything queued has finished or was stopped.
    var onFinished: (() -> Void)?


    var voiceDescription: String {
        guard let voice else { return "System voice" }
        return voice.voiceTraits.contains(.isPersonalVoice) ? "Personal Voice (\(voice.name))" : voice.name
    }

    override init() {
        super.init()
        synth.delegate = self
    }

    private(set) var personalVoiceStatus: AVSpeechSynthesizer.PersonalVoiceAuthorizationStatus = .notDetermined
    private static let savedVoiceKey = "voiceIdentifier"

    var currentVoiceIdentifier: String? { voice?.identifier }
    var currentVoice: AVSpeechSynthesisVoice? { voice }

    /// False when the current voice ignores pitch. Then the app speaks at the
    /// voice's normal pitch, whatever the slider was set to.
    var pitchWorks = true

    /// Personal Voices first, then the system voices for your language.
    var availableVoices: [AVSpeechSynthesisVoice] {
        let all = AVSpeechSynthesisVoice.speechVoices()
        let personal = all.filter { $0.voiceTraits.contains(.isPersonalVoice) }
        let lang = String(Locale.current.identifier.prefix(2))
        let system = all
            .filter { !$0.voiceTraits.contains(.isPersonalVoice) && !$0.voiceTraits.contains(.isNoveltyVoice) && $0.language.hasPrefix(lang) }
            .sorted { $0.name < $1.name }
        return personal + system
    }

    /// Asks macOS for Personal Voice access, then picks the voice: the one you
    /// chose last time, else your first Personal Voice, else the system voice.
    func setUp(completion: @escaping () -> Void) {
        AVSpeechSynthesizer.requestPersonalVoiceAuthorization { [weak self] status in
            DispatchQueue.main.async {
                guard let self else { return }
                self.personalVoiceStatus = status
                NSLog("LuisCanSpeak: Personal Voice status=\(status.rawValue) (0 notDetermined, 1 denied, 2 unsupported, 3 authorized)")
                defer { NSLog("LuisCanSpeak: using voice \(self.voiceDescription)") }
                let all = AVSpeechSynthesisVoice.speechVoices()
                if let saved = UserDefaults.standard.string(forKey: Self.savedVoiceKey) {
                    self.voice = all.first { $0.identifier == saved }
                }
                if self.voice == nil, status == .authorized {
                    self.voice = all.first { $0.voiceTraits.contains(.isPersonalVoice) }
                }
                if self.voice == nil {
                    self.voice = AVSpeechSynthesisVoice(language: Locale.current.identifier.replacingOccurrences(of: "_", with: "-"))
                }
                completion()
            }
        }
    }

    func selectVoice(identifier: String) {
        guard let v = AVSpeechSynthesisVoice(identifier: identifier) else { return }
        voice = v
        UserDefaults.standard.set(identifier, forKey: Self.savedVoiceKey)
    }

    private static let speedKey = "speechSpeed"

    /// Speed as a multiple of normal: 0.5 is half speed, 2.0 is double.
    var speed: Double {
        get {
            let saved = UserDefaults.standard.double(forKey: Self.speedKey)
            return saved == 0 ? 1.0 : saved
        }
        set { UserDefaults.standard.set(min(2.0, max(0.5, newValue)), forKey: Self.speedKey) }
    }

    /// AVSpeechUtterance rates run from 0.0 to 1.0, and 0.5 is normal speed.
    /// This maps 0.5x to 0.25, 1x to 0.5, and 2x to 1.0 (the fastest it goes).
    private var utteranceRate: Float {
        let s = speed
        let rate = s <= 1 ? 0.5 * s : 0.5 + 0.5 * (s - 1)
        return Float(rate) * (AVSpeechUtteranceMaximumSpeechRate - AVSpeechUtteranceMinimumSpeechRate)
            + AVSpeechUtteranceMinimumSpeechRate
    }

    private static func setting(_ key: String, default value: Double) -> Double {
        UserDefaults.standard.object(forKey: key) as? Double ?? value
    }

    /// Pitch as a multiple of the voice's own: 0.5 is lower, 2.0 is higher.
    var pitch: Double {
        get { Self.setting("speechPitch", default: 1.0) }
        set { UserDefaults.standard.set(min(2.0, max(0.5, newValue)), forKey: "speechPitch") }
    }

    /// Volume from 0 (silent) to 1 (full). This sits on top of the Mac's volume.
    var volume: Double {
        get { Self.setting("speechVolume", default: 1.0) }
        set { UserDefaults.standard.set(min(1.0, max(0.0, newValue)), forKey: "speechVolume") }
    }

    /// For the --probe-speaker test mode, which plays almost silently.
    var volumeOverride: Double?

    /// Seconds of silence before the app starts talking.
    var pause: Double {
        get { Self.setting("speechPause", default: 0.0) }
        set { UserDefaults.standard.set(min(3.0, max(0.0, newValue)), forKey: "speechPause") }
    }

    /// Text waiting to be spoken, one sentence or short line per entry.
    /// Long text sent as one request made Personal Voice drop parts of it, so
    /// the app speaks one piece at a time and starts the next when one finishes.
    private var queue: [Piece] = []

    private struct Piece {
        var text: String
        var delay: TimeInterval
        /// How many times the voice already stopped early on this piece.
        var retries = 0
        /// Set after too many retries, to read it with a built-in voice instead.
        var useBackupVoice = false
    }

    private var currentPiece: Piece?
    private static let maxRetries = 2
    private var current: AVSpeechUtterance?
    private var chunkNumber = 0

    var isSpeaking: Bool { current != nil || !queue.isEmpty }

    func speak(_ text: String) {
        let clean = Self.speakable(text)
        let pieces = Self.chunks(clean)
        guard !pieces.isEmpty else { return }
        SpeechLog.write("SPEAK \(clean.count) chars in \(pieces.count) pieces, voice \(voice?.identifier ?? "default")")
        for (i, piece) in pieces.enumerated() {
            queue.append(Piece(text: piece, delay: i == 0 ? pause : 0))
        }
        if current == nil { speakNext() }
    }

    func stop() {
        guard isSpeaking else { return }
        queue.removeAll()
        if current == nil {
            onFinished?()
        } else {
            synth.stopSpeaking(at: .immediate)
        }
    }

    private func speakNext() {
        guard !queue.isEmpty else {
            current = nil
            onFinished?()
            return
        }
        let next = queue.removeFirst()
        currentPiece = next
        let utterance = AVSpeechUtterance(string: next.text)
        utterance.voice = next.useBackupVoice ? Self.backupVoice : voice
        utterance.rate = utteranceRate
        utterance.pitchMultiplier = pitchWorks ? Float(pitch) : 1.0
        utterance.volume = Float(volumeOverride ?? volume)
        utterance.preUtteranceDelay = next.delay
        current = utterance
        chunkNumber += 1
        spoken[ObjectIdentifier(utterance)] = []
        SpeechLog.write("PIECE \(chunkNumber)\(next.retries > 0 ? " retry \(next.retries)" : "")\(next.useBackupVoice ? " backup voice" : ""): \(next.text)")
        synth.speak(utterance)
    }

    /// Splits text into lines, then sentences. A sentence longer than about
    /// 220 characters is split again at commas or semicolons.
    static func chunks(_ text: String) -> [String] {
        var out: [String] = []
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.rangeOfCharacter(from: .alphanumerics) != nil else { continue }
            let tokenizer = NLTokenizer(unit: .sentence)
            tokenizer.string = trimmed
            tokenizer.enumerateTokens(in: trimmed.startIndex..<trimmed.endIndex) { range, _ in
                let sentence = trimmed[range].trimmingCharacters(in: .whitespaces)
                out += splitLong(sentence, limit: 220)
                return true
            }
        }
        return out.filter { $0.rangeOfCharacter(from: .alphanumerics) != nil }
    }

    private static func splitLong(_ sentence: String, limit: Int) -> [String] {
        guard sentence.count > limit else { return [sentence] }
        var parts: [String] = []
        var piece = ""
        for clause in sentence.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "," || $0 == ";" }) {
            let addition = (piece.isEmpty ? "" : ",") + clause
            if piece.count + addition.count > limit, !piece.isEmpty {
                parts.append(piece.trimmingCharacters(in: .whitespaces) + ",")
                piece = String(clause)
            } else {
                piece += addition
            }
        }
        if !piece.trimmingCharacters(in: .whitespaces).isEmpty { parts.append(piece.trimmingCharacters(in: .whitespaces)) }
        return parts
    }

    /// The character ranges the voice said out loud, per utterance. Comparing
    /// them with the text shows which parts the voice skipped.
    private var spoken: [ObjectIdentifier: [NSRange]] = [:]

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange, utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { self.spoken[ObjectIdentifier(utterance), default: []].append(characterRange) }
    }

    /// A built-in voice for pieces Personal Voice keeps failing on, so the
    /// words still get read.
    static var backupVoice: AVSpeechSynthesisVoice? {
        AVSpeechSynthesisVoice(identifier: "com.apple.voice.compact.en-US.Samantha")
            ?? AVSpeechSynthesisVoice(language: "en-US")
    }

    /// Logs how far into a piece the voice reported getting, and returns it.
    @discardableResult
    private func logPiece(_ utterance: AVSpeechUtterance, how: String) -> Int {
        let length = (utterance.speechString as NSString).length
        let ranges = spoken.removeValue(forKey: ObjectIdentifier(utterance)) ?? []
        let reached = ranges.map { $0.location + $0.length }.max() ?? 0
        SpeechLog.write("  \(how): reached char \(reached) of \(length)")
        return reached
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            let reached = self.logPiece(utterance, how: "finished")
            guard utterance === self.current else { return }
            self.retryIfCutShort(utterance, reached: reached)
            self.speakNext()
        }
    }

    /// Personal Voice sometimes says the first word of a piece and then reports
    /// it finished. When that happens, put the unsaid part back at the front of
    /// the queue. After two failed tries, read it with the backup voice.
    private func retryIfCutShort(_ utterance: AVSpeechUtterance, reached: Int) {
        guard var piece = currentPiece else { return }
        let text = utterance.speechString as NSString
        guard reached < text.length else { return }
        let rest = text.substring(from: reached)
        guard rest.rangeOfCharacter(from: .alphanumerics) != nil,
              rest.trimmingCharacters(in: .whitespacesAndNewlines).count > 3 else { return }

        // If it stopped in the first quarter, start the piece over, since the
        // first word may not have been heard either.
        piece.text = reached < text.length / 4 ? piece.text : rest.trimmingCharacters(in: .whitespaces)
        piece.delay = 0.1
        piece.retries += 1
        if piece.retries > Self.maxRetries {
            if piece.useBackupVoice { return }  // even the backup failed; move on
            piece.useBackupVoice = true
        }
        SpeechLog.write("  cut short, queueing again: \(piece.text)")
        queue.insert(piece, at: 0)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            self.logPiece(utterance, how: "stopped")
            guard utterance === self.current else { return }
            self.speakNext()  // the queue is empty after stop(), so this ends it
        }
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
            line = stripEmphasisOutsideCode(line)
            line = line.replacingOccurrences(of: "`", with: "")
            line = speakablePaths(line)
            // Table rows: "| a | b |" becomes "a, b." so each row reads as a sentence.
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                let cells = line.split(separator: "|")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                line = cells.joined(separator: ", ") + "."
            } else {
                line = line.replacingOccurrences(of: "|", with: ", ")
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Removes ** and __ but leaves them inside `code`, where they're real text.
    private static func stripEmphasisOutsideCode(_ line: String) -> String {
        line.components(separatedBy: "`").enumerated().map { index, part in
            index % 2 == 1 ? part : part.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "")
        }.joined(separator: "`")
    }

    /// Personal Voice drops the rest of a sentence after a file path like
    /// ~/Library/Application Support/Luis Can Speak/speech.log. So paths become
    /// "the speech dot log file", and names like main.swift become "main dot swift".
    static func speakablePaths(_ line: String) -> String {
        var line = line
        // A path that starts with ~ or / and ends in a file name with an extension.
        line = line.replacingOccurrences(
            of: #"(?:~|\.{1,2})?/[^\n,;()"]*?/([A-Za-z0-9_\-]+\.[A-Za-z0-9]+)\b"#,
            with: "the $1 file", options: .regularExpression)
        // Any other path made of slash-separated words: say only the last part.
        line = line.replacingOccurrences(
            of: #"(?:~|\.{1,2})?/(?:[A-Za-z0-9_.\-]+/)+([A-Za-z0-9_\-]+)/?"#,
            with: "the $1 folder", options: .regularExpression)
        // Dots between letters, as in file names and bundle IDs.
        line = line.replacingOccurrences(of: #"(?<=[A-Za-z])\.(?=[A-Za-z])"#, with: " dot ", options: .regularExpression)
        return line
    }
}

/// Writes speech.log next to the custom words file, newest at the bottom.
enum SpeechLog {
    static var url: URL { CustomWords.fileURL.deletingLastPathComponent().appendingPathComponent("speech.log") }

    static func write(_ line: String) {
        let text = "--- \(Date())\n\(line)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
