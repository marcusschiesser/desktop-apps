# Flow Dictation

A private, local-first macOS dictation app built with [Vercel Native SDK](https://github.com/vercel-labs/native). It is based on the [Wispr Flow replacement prompt](https://canivibecodeit.com/wispr-flow) from Can I Vibecode It.

Hold **Command + Shift + Space**, speak, and release. Flow Dictation records the microphone, transcribes the audio, optionally cleans the text, pastes it into the focused app, and restores the previous clipboard contents.

## What works

- System-wide hold-to-talk shortcut
- Native floating recording/transcribing pill
- Local transcription through `whisper.cpp`
- OpenAI transcription fallback when `OPENAI_API_KEY` is available
- Optional LLM cleanup for filler words, punctuation, and casing
- Paste-at-cursor through the macOS pasteboard and Command-V
- Full clipboard item snapshot and restoration
- Menu-bar enable/disable control
- Native SDK settings and diagnostics window
- No accounts, analytics, or telemetry

## Requirements

- macOS 15 or newer
- Node.js 22+
- Xcode Command Line Tools
- Optional: `whisper-cli` from [whisper.cpp](https://github.com/ggml-org/whisper.cpp) and a GGML model
- Optional: `OPENAI_API_KEY` for API transcription and cleanup

## Run

```bash
npm install
npm run dev
```

The first run asks for Microphone and Accessibility permission. After granting Accessibility permission, restart the helper from the app window.

## Configure

Click **Open config.json** or edit:

```text
~/Library/Application Support/Flow Dictation/config.json
```

For fully local transcription, set `transcriptionProvider` to `local` and configure absolute `whisperCliPath` and `whisperModelPath` values. Set it to `openai` to use the API directly. When local Whisper fails and `OPENAI_API_KEY` exists, the helper falls back to the API and reports that in the status view.

## Test and build

```bash
npm test
npm run build
```

`npm test` compiles and codesigns the Swift helper, runs its config/cleanup/multipart self-tests, and runs `native check` against the TypeScript core, native markup, and manifest.

## Architecture

- `src/core.ts` — deterministic Native SDK TypeScript model/update loop
- `src/app.native` — native settings and status interface
- `native/FlowShared.swift` — configuration, local cleanup, multipart construction, and self-tests
- `native/FlowMac.swift` — global hotkey, microphone recording, transcription, floating pill, menu bar, clipboard, and paste integration
- `native/FlowMain.swift` — helper command entry point
- `scripts/build-helper.sh` — Swift compilation and ad-hoc code signing
- `PROMPT.md` — the Codex-optimized build specification

## Deliberate limitations

- Launch-at-login is not registered automatically. Add the packaged app under **System Settings → General → Login Items**.
- This MVP targets macOS only.
- Local Whisper setup is explicit rather than downloading large models without consent.
