# Codex build prompt: Flow Dictation

You are Codex working for **Marcus Schiesser**, a senior TypeScript and AI systems engineer. Build a production-minded, local-first macOS dictation app named **Flow Dictation** in the `flow-dictation/` directory of `marcusschiesser/desktop-apps`.

The product is inspired by the Can I Vibecode It prompt for [Wispr Flow](https://canivibecodeit.com/wispr-flow), but it must be an original implementation and must not use Wispr branding, assets, code, or proprietary services.

## Non-negotiable stack

- Use the current stable `@native-sdk/cli` from [vercel-labs/native](https://github.com/vercel-labs/native).
- Build the desktop UI with Native SDK native markup and a TypeScript core. Do not use Electron, Tauri, a browser runtime, React, or a WebView.
- Use a small Swift helper only for macOS APIs not exposed directly by Native SDK: global keyboard events, AVAudioEngine capture, NSStatusItem, the floating NSPanel, Accessibility-based paste, and clipboard restoration.
- Keep the app local-first, account-free, telemetry-free, and understandable from the repository.

## Core user loop

1. Run in the background with a menu-bar item.
2. Marcus holds a configurable shortcut, default Command + Shift + Space.
3. Record the microphone and show `Listening…`.
4. On release, show `Transcribing…` and transcribe.
5. Prefer local `whisper.cpp` with configured absolute paths.
6. Fall back to an OpenAI-compatible `/audio/transcriptions` endpoint only when configured and `OPENAI_API_KEY` exists.
7. Optionally clean filler words, punctuation, and casing through a chat completion, with deterministic local cleanup fallback.
8. Snapshot every pasteboard item, synthesize Command-V, then restore the clipboard.
9. Report the result in the Native SDK status window.

## Native SDK UI

Use `src/app.native` and `src/core.ts` for current helper state, workflow explanation, permissions, restart, config opening, diagnostics, and session restart count. Start the Swift helper with keyed `Cmd.spawn`, stream stdout into the model, and support cancellation/restart without orphaned processes.

## Configuration

Persist human-editable JSON at `~/Library/Application Support/Flow Dictation/config.json`. Include enabled state, key code, modifiers, provider, local Whisper paths, compatible API base URL, models, language, and clipboard restore delay. Never persist API keys.

## Privacy and safety

- No accounts, telemetry, crash upload, analytics, or hidden network calls.
- Delete successful temporary recordings.
- Request permissions only when needed.
- Use a listen-only event tap and never suppress unrelated keys.
- Never paste without an explicit shortcut hold/release.
- Never silently download models or execute shell strings.

## Acceptance criteria

- `npm test` succeeds on a macOS GitHub Actions runner.
- Swift self-tests cover config round-trip, deterministic cleanup, and multipart construction.
- `native check` succeeds.
- No Electron, Tauri, React, WebView, account, or telemetry dependency.
- README documents install, permissions, local setup, API fallback, tests, build, architecture, and honest limitations.
- Root README links this directory and the Can I Vibecode It page.
- Do not overwrite or duplicate an existing app directory.

Prefer a small, reliable implementation over speculative abstraction. Keep system integration in Swift, state/orchestration in the Native SDK TypeScript core, and presentation in native markup.
