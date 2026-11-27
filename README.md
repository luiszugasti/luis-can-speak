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
