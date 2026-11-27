import AppKit
import Carbon
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    enum Mode {
        case idle
        case recording
        case transcribing
        case waitingForClaude
        case speaking
    }

    private var statusItem: NSStatusItem!
    private var hotKey: HotKey?
    private let server = HookServer()
    private let dictation = Dictation()
    private let speaker = Speaker()

    private var mode: Mode = .idle { didSet { updateIcon() } }
    private var pending: [PendingDecision] = []
    private var pendingTimers: [ObjectIdentifier: Timer] = [:]
    /// True from when the app sends a voice prompt until Claude finishes that turn.
    /// Prompts and replies are only handled by voice during a voice turn, so
    /// typing in the same session still gets the normal terminal dialogs.
    private var voiceTurnActive = false
    /// True while the speaker is reading a prompt that waits on an answer.
    private var speakingPrompt = false
    private var lastHeard = ""
    private var lastError = ""

    private let defaults = UserDefaults.standard
    private var linkedSurface: String? {
        get { defaults.string(forKey: "linkedSurface") }
        set { defaults.set(newValue, forKey: "linkedSurface") }
    }
    private var linkedCwd: String? {
        get { defaults.string(forKey: "linkedCwd") }
        set { defaults.set(newValue, forKey: "linkedCwd") }
    }
    private var readEveryReply: Bool {
        get { defaults.bool(forKey: "readEveryReply") }
        set { defaults.set(newValue, forKey: "readEveryReply") }
    }
    private var relinkOnNextPrompt = false

    // Pending answers wait at most this long, then go back to the terminal.
    // The hook script gives up at 590 seconds, and Claude Code at 600.
    private let decisionTimeout: TimeInterval = 570

    // MARK: Startup

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateIcon()

        relinkOnNextPrompt = linkedSurface == nil

        hotKey = HotKey(keyCode: kVK_Space, modifiers: controlKey | optionKey) { [weak self] in
            MainActor.assumeIsolated { self?.hotKeyPressed() }
        }

        speaker.onFinished = { [weak self] in
            MainActor.assumeIsolated { self?.speechFinished() }
        }
        speaker.setUp { [weak self] in self?.checkPitch() }

        dictation.onPartial = { [weak self] text in
            MainActor.assumeIsolated { self?.statusItem.button?.toolTip = text }
        }

        server.onRequest = { [weak self] request in
            MainActor.assumeIsolated { self?.handle(request) }
        }
        do {
            try server.start()
        } catch {
            lastError = "Couldn't listen on port \(HookServer.port): \(error.localizedDescription)"
        }

        Task {
            do { try await Dictation.prepareModel() } catch { self.lastError = error.localizedDescription }
        }

        CustomWords.ensureFile()
        setUpLoginAndGreeting()
    }

    // MARK: Hotkey

    private func hotKeyPressed() {
        switch mode {
        case .speaking:
            let wasPrompt = speakingPrompt
            speaker.stop()
            // Cutting off a question means you want to answer it now.
            if wasPrompt { startRecording() }
        case .recording:
            stopRecording()
        case .transcribing:
            NSSound.beep()
        case .idle, .waitingForClaude:
            startRecording()
        }
    }

    private func startRecording() {
        guard !speaker.isSpeaking else { return }
        mode = .recording
        NSSound(named: "Tink")?.play()
        Task {
            do {
                try await dictation.start()
            } catch {
                self.fail(error.localizedDescription)
            }
        }
    }

    private func stopRecording() {
        mode = .transcribing
        NSSound(named: "Pop")?.play()
        Task {
            let text = await dictation.stop()
            self.statusItem.button?.toolTip = nil
            self.heard(text)
        }
    }

    private func heard(_ text: String) {
        mode = voiceTurnActive ? .waitingForClaude : .idle
        guard !text.isEmpty else {
            NSSound.beep()
            return
        }
        lastHeard = text

        if let decision = pending.first {
            answer(decision, with: text)
            return
        }
        send(text)
    }

    private func send(_ text: String) {
        guard let surface = linkedSurface else {
            fail("Not linked to a Claude session yet. Type any prompt in the session you want, then try again.")
            return
        }
        voiceTurnActive = true
        mode = .waitingForClaude
        Task.detached {
            let error = Terminal.submit(text, surface: surface)
            await MainActor.run {
                if let error {
                    self.voiceTurnActive = false
                    self.fail("Couldn't send to Claude: \(error)")
                }
            }
        }
    }

    // MARK: Hooks from Claude Code

    private func handle(_ request: HookRequest) {
        let body = request.body

        if request.event == "UserPromptSubmit" {
            if relinkOnNextPrompt, !request.surface.isEmpty {
                linkedSurface = request.surface
                linkedCwd = body["cwd"] as? String
                relinkOnNextPrompt = false
                NSSound(named: "Glass")?.play()
            }
            request.reply()
            return
        }

        guard !request.surface.isEmpty, request.surface == linkedSurface else {
            request.reply()
            return
        }

        switch request.event {
        case "Stop":
            request.reply()
            let shouldRead = voiceTurnActive || readEveryReply
            voiceTurnActive = false
            dropAllPending()
            if let text = body["last_assistant_message"] as? String {
                lastReply = text
                SpeechLog.write("STOP HOOK: reply is \(text.count) chars")
            }
            if shouldRead, let text = body["last_assistant_message"] as? String, !text.isEmpty {
                say(text, isPrompt: false)
            } else if mode == .waitingForClaude {
                mode = .idle
            }

        case "StopFailure":
            request.reply()
            if voiceTurnActive {
                voiceTurnActive = false
                say("Claude hit an error and stopped. Check the terminal.", isPrompt: false)
            }

        case "PermissionRequest":
            let tool = body["tool_name"] as? String ?? "a tool"
            let input = body["tool_input"] as? [String: Any] ?? [:]
            // AskUserQuestion is answered in PreToolUse, so let it through here.
            guard voiceTurnActive, tool != "AskUserQuestion" else {
                request.reply()
                return
            }
            if tool == "ExitPlanMode" {
                enqueue(PendingDecision(request: request, kind: .plan(input: input)))
            } else {
                let suggestions = body["permission_suggestions"] as? [[String: Any]] ?? []
                enqueue(PendingDecision(request: request, kind: .permission(tool: tool, input: input, suggestions: suggestions)))
            }

        case "PreToolUse":
            let input = body["tool_input"] as? [String: Any] ?? [:]
            let questions = input["questions"] as? [[String: Any]] ?? []
            guard voiceTurnActive, body["tool_name"] as? String == "AskUserQuestion", !questions.isEmpty else {
                request.reply()
                return
            }
            enqueue(PendingDecision(request: request, kind: .questions(input: input, questions: questions, index: 0, answers: [:])))

        case "Elicitation":
            guard voiceTurnActive else {
                request.reply()
                return
            }
            let schema = body["requested_schema"] as? [String: Any]
            let fields = schema?["properties"] as? [String: Any] ?? [:]
            let server = body["mcp_server_name"] as? String ?? "MCP"
            if fields.isEmpty, body["mode"] as? String != "url" {
                enqueue(PendingDecision(request: request, kind: .elicitation(server: server)))
            } else {
                request.reply()
                say("The \(server) tool needs you to fill in a form. Answer it in the terminal.", isPrompt: false)
            }

        default:
            request.reply()
        }
    }

    // MARK: Decisions

    private func enqueue(_ decision: PendingDecision) {
        pending.append(decision)
        let id = ObjectIdentifier(decision)
        pendingTimers[id] = Timer.scheduledTimer(withTimeInterval: decisionTimeout, repeats: false) { [weak self, weak decision] _ in
            MainActor.assumeIsolated {
                guard let self, let decision else { return }
                self.finish(decision, reply: [:])
                self.say("You didn't answer, so I left that one for the terminal.", isPrompt: false)
            }
        }
        if pending.count == 1 { ask(decision) }
    }

    private func ask(_ decision: PendingDecision) {
        if mode == .recording { return }  // asked once you finish talking
        say(decision.spokenPrompt, isPrompt: true)
    }

    private func answer(_ decision: PendingDecision, with said: String) {
        switch decision.kind {
        case let .permission(_, _, suggestions):
            switch AnswerParser.yesNo(said) {
            case .yes: finish(decision, reply: permissionReply(allow: true))
            case .always: finish(decision, reply: permissionReply(allow: true, permissions: suggestions))
            case let .no(message): finish(decision, reply: permissionReply(allow: false, message: message))
            case .cancel: finish(decision, reply: permissionReply(allow: false, message: "The user cancelled.", interrupt: true))
            case .terminal: finish(decision, reply: [:])
            case .unclear: say("I didn't catch that. " + decision.spokenPrompt, isPrompt: true)
            }

        case let .plan(input):
            switch AnswerParser.yesNo(said) {
            case .yes, .always: finish(decision, reply: permissionReply(allow: true, updatedInput: input))
            case let .no(message): finish(decision, reply: permissionReply(allow: false, message: message))
            case .cancel: finish(decision, reply: permissionReply(allow: false, message: "The user cancelled.", interrupt: true))
            case .terminal: finish(decision, reply: [:])
            case .unclear: say("I didn't catch that. Do you approve the plan? Say yes or no.", isPrompt: true)
            }

        case let .questions(input, questions, index, answers):
            if AnswerParser.yesNo(said) == .terminal {
                finish(decision, reply: [:])
                return
            }
            let q = questions[index]
            let labels = (q["options"] as? [[String: Any]] ?? []).map { $0["label"] as? String ?? "" }
            let multi = q["multiSelect"] as? Bool ?? false
            var answers = answers
            answers[q["question"] as? String ?? "Question \(index + 1)"] =
                AnswerParser.optionAnswer(said, options: labels, multiSelect: multi)

            if index + 1 < questions.count {
                decision.kind = .questions(input: input, questions: questions, index: index + 1, answers: answers)
                say(decision.spokenPrompt, isPrompt: true)
            } else {
                var updated = input
                updated["answers"] = answers
                finish(decision, reply: [
                    "hookSpecificOutput": [
                        "hookEventName": "PreToolUse",
                        "permissionDecision": "allow",
                        "updatedInput": updated,
                    ]
                ])
            }

        case .elicitation:
            switch AnswerParser.yesNo(said) {
            case .yes, .always: finish(decision, reply: elicitationReply("accept"))
            case .no: finish(decision, reply: elicitationReply("decline"))
            case .cancel: finish(decision, reply: elicitationReply("cancel"))
            case .terminal: finish(decision, reply: [:])
            case .unclear: say("I didn't catch that. Say yes or no.", isPrompt: true)
            }
        }
    }

    private func finish(_ decision: PendingDecision, reply: [String: Any]) {
        let id = ObjectIdentifier(decision)
        pendingTimers[id]?.invalidate()
        pendingTimers[id] = nil
        decision.request.reply(reply)
        pending.removeAll { $0 === decision }
        if let next = pending.first {
            ask(next)
        } else if mode != .speaking, mode != .recording {
            mode = voiceTurnActive ? .waitingForClaude : .idle
        }
    }

    /// Hands every open prompt back to the terminal.
    private func dropAllPending() {
        for decision in pending { finish(decision, reply: [:]) }
    }

    private func permissionReply(
        allow: Bool,
        message: String? = nil,
        interrupt: Bool = false,
        permissions: [[String: Any]] = [],
        updatedInput: [String: Any]? = nil
    ) -> [String: Any] {
        var decision: [String: Any] = ["behavior": allow ? "allow" : "deny"]
        if allow {
            if !permissions.isEmpty { decision["updatedPermissions"] = permissions }
            if let updatedInput { decision["updatedInput"] = updatedInput }
        } else {
            decision["message"] = "The user said no, by voice: \"\(message ?? "no")\""
            if interrupt { decision["interrupt"] = true }
        }
        return ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]]
    }

    private func elicitationReply(_ action: String) -> [String: Any] {
        var out: [String: Any] = ["hookEventName": "Elicitation", "action": action]
        if action == "accept" { out["content"] = [String: Any]() }
        return ["hookSpecificOutput": out]
    }

    // MARK: Speech

    private func say(_ text: String, isPrompt: Bool) {
        // Never record while speaking: stop any recording first.
        if mode == .recording {
            Task { await dictation.cancel() }
        }
        speakingPrompt = isPrompt
        mode = .speaking
        speaker.speak(text)
    }

    private func speechFinished() {
        speakingPrompt = false
        guard mode == .speaking else { return }
        mode = voiceTurnActive || !pending.isEmpty ? .waitingForClaude : .idle
    }

    private func fail(_ message: String) {
        lastError = message
        mode = voiceTurnActive ? .waitingForClaude : .idle
        NSSound(named: "Basso")?.play()
        NSLog("LuisCanSpeak: \(message)")
    }

    // MARK: Menu bar

    private func updateIcon() {
        guard let button = statusItem?.button else { return }
        let symbol: String
        switch mode {
        case .idle: symbol = pending.isEmpty ? "mic" : "questionmark.bubble"
        case .recording: symbol = "mic.fill"
        case .transcribing: symbol = "waveform"
        case .waitingForClaude: symbol = pending.isEmpty ? "ellipsis.bubble" : "questionmark.bubble"
        case .speaking: symbol = "speaker.wave.2.fill"
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Luis Can Speak")
        image?.isTemplate = mode != .recording
        button.image = image
        button.contentTintColor = mode == .recording ? .systemRed : nil
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        func info(_ title: String) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        func action(_ title: String, _ selector: Selector, tag: Int = 0, on: Bool = false) {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            item.target = self
            item.tag = tag
            item.state = on ? .on : .off
            menu.addItem(item)
        }

        let state: String
        switch mode {
        case .idle: state = "Ready. Press ⌃⌥Space to talk."
        case .recording: state = "Listening. Press ⌃⌥Space to send."
        case .transcribing: state = "Finishing the transcript…"
        case .waitingForClaude: state = "Waiting for Claude…"
        case .speaking: state = "Speaking. Press ⌃⌥Space to stop."
        }
        info(state)

        if relinkOnNextPrompt {
            info("Linking: type any prompt in the Claude session you want")
        } else if let cwd = linkedCwd {
            info("Linked to the Claude session in \((cwd as NSString).lastPathComponent)")
        }
        action("Link to the next prompt I type", #selector(relink))

        if let decision = pending.first {
            menu.addItem(.separator())
            info(decision.menuTitle)
            switch decision.kind {
            case let .permission(_, _, suggestions):
                action("Allow", #selector(menuAnswer(_:)), tag: 1)
                if !suggestions.isEmpty { action("Always allow", #selector(menuAnswer(_:)), tag: 2) }
                action("Deny", #selector(menuAnswer(_:)), tag: 3)
            case .plan, .elicitation:
                action("Yes", #selector(menuAnswer(_:)), tag: 1)
                action("No", #selector(menuAnswer(_:)), tag: 3)
            case let .questions(_, questions, index, _):
                let options = questions[index]["options"] as? [[String: Any]] ?? []
                for (i, option) in options.enumerated() {
                    action("\(i + 1). \(option["label"] as? String ?? "")", #selector(menuOption(_:)), tag: i + 1)
                }
            }
            action("Answer in the terminal instead", #selector(menuAnswer(_:)), tag: 4)
        }

        if !lastHeard.isEmpty {
            menu.addItem(.separator())
            info("Last heard: " + String(lastHeard.prefix(60)) + (lastHeard.count > 60 ? "…" : ""))
        }
        if !lastError.isEmpty {
            info("⚠️ " + String(lastError.prefix(90)))
        }

        menu.addItem(.separator())
        action("Read every reply in the linked session", #selector(toggleReadEveryReply), on: readEveryReply)
        let voiceItem = NSMenuItem(title: "Voice: \(speaker.voiceDescription)", action: nil, keyEquivalent: "")
        let voiceMenu = NSMenu()
        if speaker.personalVoiceStatus != .authorized {
            let note = NSMenuItem(title: "Personal Voice isn't allowed. Turn it on in System Settings > Privacy & Security > Personal Voice.", action: nil, keyEquivalent: "")
            note.isEnabled = false
            voiceMenu.addItem(note)
            voiceMenu.addItem(.separator())
        }
        for v in speaker.availableVoices {
            let personal = v.voiceTraits.contains(.isPersonalVoice)
            let item = NSMenuItem(title: personal ? "\(v.name) (Personal Voice)" : v.name, action: #selector(pickVoice(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = v.identifier
            item.state = v.identifier == speaker.currentVoiceIdentifier ? .on : .off
            voiceMenu.addItem(item)
        }
        voiceItem.submenu = voiceMenu
        menu.addItem(voiceItem)
        sliderRows = [
            SliderRow(
                value: speaker.speed, range: 0.5...2.0, steps: 7,
                format: { "Speed: " + String(format: "%g", $0) + "×" + ($0 == 1 ? " (normal)" : "") },
                onChange: { [weak self] in self?.speaker.speed = $0 },
                onRelease: { [weak self] in self?.testVoice() }
            ),
            SliderRow(
                value: speaker.pitchWorks ? speaker.pitch : 1.0, range: 0.5...2.0, steps: 7,
                enabled: speaker.pitchWorks,
                toolTip: speaker.pitchWorks ? nil
                    : (speaker.currentVoice?.voiceTraits.contains(.isPersonalVoice) ?? false)
                        ? "Personal Voice ignores pitch changes. macOS also keeps apps from recording Personal Voice, so the app can't measure it. Pick a built-in Apple voice to change pitch."
                        : "This voice ignores pitch changes. The app tested it at low and high pitch, and it sounded the same both times.",
                format: { [weak self] value in
                    guard self?.speaker.pitchWorks ?? true else { return "Pitch: this voice can't change it" }
                    return "Pitch: " + String(format: "%g", value) + "×" + (value == 1 ? " (normal)" : "")
                },
                onChange: { [weak self] in self?.speaker.pitch = $0 },
                onRelease: { [weak self] in self?.testVoice() }
            ),
            SliderRow(
                value: speaker.volume, range: 0...1, steps: 11,
                format: { "Volume: \(Int(($0 * 100).rounded()))%" },
                onChange: { [weak self] in self?.speaker.volume = $0 },
                onRelease: { [weak self] in self?.testVoice() }
            ),
            SliderRow(
                value: speaker.pause, range: 0...3, steps: 13,
                format: { $0 == 0 ? "Pause before talking: none" : "Pause before talking: " + String(format: "%g", $0) + " s" },
                onChange: { [weak self] in self?.speaker.pause = $0 },
                onRelease: {}
            ),
        ]
        for row in sliderRows { menu.addItem(row.item) }
        action("Test the voice", #selector(testVoice))
        if !lastReply.isEmpty { action("Read the last reply again", #selector(replayLastReply)) }

        menu.addItem(.separator())
        let languageItem = NSMenuItem(title: "Dictation language", action: nil, keyEquivalent: "")
        let languageMenu = NSMenu()
        for (index, language) in Dictation.languages.enumerated() {
            let item = NSMenuItem(title: language.name, action: #selector(pickLanguage(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.state = language.id == Dictation.languageID ? .on : .off
            languageMenu.addItem(item)
        }
        languageItem.submenu = languageMenu
        menu.addItem(languageItem)
        action("Edit custom words…", #selector(editCustomWords))

        menu.addItem(.separator())
        let login = SMAppService.mainApp.status
        action("Open at login", #selector(toggleOpenAtLogin), on: login == .enabled)
        if login == .requiresApproval {
            info("Allow it in System Settings > General > Login Items")
        }
        action("Greet me when I unlock the Mac", #selector(toggleGreeting), on: greetOnUnlock)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Luis Can Speak", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    /// Kept alive while the menu is open, since each row is its slider's target.
    private var sliderRows: [SliderRow] = []

    @objc private func pickLanguage(_ sender: NSMenuItem) {
        Dictation.languageID = Dictation.languages[sender.tag].id
        // Download the speech model for the new language now, so the next
        // recording doesn't wait for it.
        Task {
            do { try await Dictation.prepareModel() } catch { self.lastError = error.localizedDescription }
        }
    }

    @objc private func editCustomWords() {
        CustomWords.ensureFile()
        NSWorkspace.shared.open(CustomWords.fileURL)
    }

    // MARK: Login and unlock

    private var greetOnUnlock: Bool {
        get { defaults.object(forKey: "greetOnUnlock") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "greetOnUnlock") }
    }

    /// Turns on "Open at login" the first time the app runs. After that, the
    /// menu toggle decides.
    private func setUpLoginAndGreeting() {
        if !defaults.bool(forKey: "loginItemSetUp") {
            defaults.set(true, forKey: "loginItemSetUp")
            do { try SMAppService.mainApp.register() } catch { lastError = "Couldn't turn on Open at login: \(error.localizedDescription)" }
        }
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.greet() }
        }
    }

    private func greet() {
        guard greetOnUnlock, mode == .idle else { return }
        let hour = Calendar.current.component(.hour, from: Date())
        let part = hour < 12 ? "Good morning" : hour < 18 ? "Good afternoon" : "Good evening"
        let name = NSFullUserName().split(separator: " ").first.map(String.init) ?? ""
        let spanish = Dictation.languageID.hasPrefix("es")
        let greeting: String
        if spanish {
            let parte = hour < 12 ? "Buenos días" : hour < 18 ? "Buenas tardes" : "Buenas noches"
            greeting = "\(parte), \(name). Bienvenido de vuelta."
        } else {
            greeting = "\(part), \(name). Welcome back."
        }
        say(greeting, isPrompt: false)
    }

    @objc private func toggleOpenAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            lastError = "Couldn't change Open at login: \(error.localizedDescription)"
        }
    }

    @objc private func toggleGreeting() {
        greetOnUnlock.toggle()
    }

    /// Tests the current voice for pitch support in the background. Until the
    /// test finishes, the slider stays on.
    private func checkPitch() {
        guard let voice = speaker.currentVoice else { return }
        if let known = PitchProbe.cached(voice) {
            speaker.pitchWorks = known
            return
        }
        speaker.pitchWorks = true
        Task {
            let works = await PitchProbe.supportsPitch(voice)
            if self.speaker.currentVoice?.identifier == voice.identifier {
                self.speaker.pitchWorks = works
            }
        }
    }

    @objc private func pickVoice(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        speaker.selectVoice(identifier: id)
        checkPitch()
        testVoice()
    }

    private var lastReply = ""

    @objc private func replayLastReply() {
        if mode == .speaking { speaker.stop() }
        say(lastReply, isPrompt: false)
    }

    @objc private func testVoice() {
        if mode == .speaking { speaker.stop() }
        say("Hi, this is Luis Can Speak. This is how I'll read Claude's replies to you.", isPrompt: false)
    }

    @objc private func relink() {
        relinkOnNextPrompt = true
    }

    @objc private func toggleReadEveryReply() {
        readEveryReply.toggle()
    }

    @objc private func menuAnswer(_ sender: NSMenuItem) {
        guard let decision = pending.first else { return }
        if mode == .speaking { speaker.stop() }
        switch sender.tag {
        case 1: answer(decision, with: "yes")
        case 2: answer(decision, with: "always")
        case 3: answer(decision, with: "no")
        default: finish(decision, reply: [:])
        }
    }

    @objc private func menuOption(_ sender: NSMenuItem) {
        guard let decision = pending.first else { return }
        if mode == .speaking { speaker.stop() }
        answer(decision, with: String(sender.tag))
    }
}
