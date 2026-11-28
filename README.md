# Luis Can Speak

A menu bar app that lets you talk to a Claude Code session running in cmux.
Speech-to-text and text-to-speech both run on this Mac. Your audio never
leaves it. The text of your prompt still goes to Anthropic, like typing does.

## How it works

1. You press **⌃⌥Space**, talk, and press **⌃⌥Space** again.
2. Apple's on-device speech engine (SpeechAnalyzer, macOS 26) turns it into text.
3. The app pastes the text into the linked Claude Code session with
   `cmux paste --submit`.
4. Claude Code hooks call the app on `127.0.0.1:47321`:
   - `Stop` hands over Claude's final reply, and the app reads all of it aloud.
   - `PermissionRequest`, `PreToolUse` (AskUserQuestion) and `Elicitation`
     wait while the app reads the question and you answer out loud.
5. Pressing **⌃⌥Space** while it talks stops the speech. If it was reading a
   question, it starts listening for your answer right away.

The app only takes over prompts during a turn you started by voice. If you
type in the same session, you get the normal terminal dialogs.

## Before you try it

This is a personal project. There's no release or installer, so you build it
from source. Know these limits first:

- **macOS will block the app.** It's signed locally, without an Apple
  Developer ID, and Apple doesn't check it (notarize it). If you copy the
  built app to another Mac, macOS blocks it. To open it anyway, go to
  System Settings > Privacy & Security and click "Open Anyway." Building it on
  your own Mac avoids this.
- **It needs macOS 26 on Apple Silicon.** Apple's on-device speech engine
  (SpeechAnalyzer) needs macOS 26. The build script only makes an Apple Silicon
  app.
- **It only works with cmux.** The app types prompts into Claude Code through
  cmux, at `/Applications/cmux.app`. Without cmux, the app can't send anything to
  Claude.
- **The hooks point at this folder.** `install-hooks.sh` adds hooks to
  `~/.claude/settings.json` that run the script in this repo's `hooks` folder.
  If you move or delete the repo, run `./scripts/install-hooks.sh --uninstall`
  first, or the hooks will point at a missing file.
- **macOS asks for permissions.** On first launch, you'll be asked for the
  microphone, speech recognition and Personal Voice. Every rebuild changes the
  local signature, so macOS may ask again.
- **It makes choices for you.** On first launch, it turns on Open at login. It
  also greets you by your first name when you unlock your Mac. You can turn both
  off in the menu bar menu.
- **The hotkey and port are fixed.** The hotkey is ⌃⌥Space, and the hook server
  uses port 47321. If another app uses either one, this app won't work.
- **The hook server doesn't check who's calling.** Any program on your Mac can
  send it requests. A request can't approve anything in Claude Code on its own,
  but it could make the app speak or relink it to a different session.
- **Parakeet is a big download.** If you pick Parakeet as the speech-to-text
  engine, it downloads about 600 MB the first time.
- **It doesn't update itself.** To update, pull the repo and run the build
  script again.

## Setup

```sh
./scripts/build-app.sh
./scripts/install-hooks.sh        # backs up ~/.claude/settings.json first
open 'build/Luis Can Speak.app'
```

Then type any prompt in the Claude session you want to link. The app links to
the first session you type in, and the menu shows which one.

For your own voice, set up Personal Voice in System Settings > Accessibility >
Personal Voice, and allow Luis Can Speak to use it when macOS asks.

To remove the hooks: `./scripts/install-hooks.sh --uninstall`.

## Answering prompts by voice

| Prompt | What you can say |
| --- | --- |
| Tool permission (Bash, Edit, WebFetch, MCP tools) | "yes", "no, use pnpm instead" (Claude sees your words), "always" (saves Claude's suggested rule), "cancel" (stops Claude) |
| Plan approval (ExitPlanMode) | "yes", or "no" plus what to change |
| Multiple-choice question (AskUserQuestion) | an option number, an option's name, or your own answer |
| MCP yes-or-no confirmation | "yes", "no", "cancel" |
| MCP form with fields, or a URL sign-in | the app tells you to answer in the terminal |

Saying "terminal" on any prompt hands it back to the terminal dialog. The menu
bar menu has buttons for every answer too. If you don't answer in about 9.5
minutes, the app hands the prompt back to the terminal.
