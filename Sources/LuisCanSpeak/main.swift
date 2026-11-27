import AppKit

let args = CommandLine.arguments

// Test hook: `open -n "Luis Can Speak.app" --args --probe-speech <in.txt> <out.txt>`
// speaks each line of in.txt almost silently with the saved voice and
// writes how far into each line the voice got. It doesn't start the menu bar app.
if let i = args.firstIndex(of: "--probe-speech"), i + 2 < args.count {
    let lines = ((try? String(contentsOfFile: args[i + 1], encoding: .utf8)) ?? "")
        .components(separatedBy: .newlines).filter { !$0.isEmpty }
    let outPath = args[i + 2]
    Task { @MainActor in
        let report = await SpeechProbe.run(lines)
        try? report.write(toFile: outPath, atomically: true, encoding: .utf8)
        exit(0)
    }
    RunLoop.main.run()
}

// Test hook: `open -n "Luis Can Speak.app" --args --probe-speaker <in.txt>`
// reads in.txt through the real speaker queue, almost silently, then exits.
// The pieces, retries and backup-voice use land in speech.log.
if let i = args.firstIndex(of: "--probe-speaker"), i + 1 < args.count {
    let text = (try? String(contentsOfFile: args[i + 1], encoding: .utf8)) ?? ""
    MainActor.assumeIsolated {
        let speaker = Speaker()
        speaker.volumeOverride = 0.001
        speaker.onFinished = { exit(0) }
        speaker.setUp {
            SpeechLog.write("PROBE START")
            speaker.speak(text)
        }
        withExtendedLifetime(speaker) { RunLoop.main.run() }
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
}
