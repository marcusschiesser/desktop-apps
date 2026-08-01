# Local Meeting Notes

A private macOS menu-bar meeting recorder built with the
[Vercel Native SDK](https://github.com/vercel-labs/native). The interface is a
native Zig/Metal canvas with an `NSStatusItem` tray menu—there is no Electron,
browser engine, account system, telemetry, sync, or app-managed cloud storage.

The app:

1. Captures system audio and microphone audio with Apple ScreenCaptureKit.
2. Mixes and converts both tracks with AVFoundation; no external audio tool is
   needed.
3. Transcribes locally using a bundled `whisper.cpp` executable and the
   multilingual medium model.
4. Sends only the transcript to OpenAI GPT-5.6 Luna to produce exactly five
   summary bullets, decisions, and owner-attributed action items.
5. Saves the Markdown note and retained `.wav` audio in `~/MeetingNotes`.

## Output

Each recording produces files such as:

```text
~/MeetingNotes/2026-07-31-1430.md
~/MeetingNotes/2026-07-31-1430.wav
```

The Markdown layout is:

```markdown
# Meeting Notes — 2026-07-31-1430

## Summary
- Five concise bullets

## Decisions
- Explicitly supported decisions

## Action Items
- [ ] Owner — action

---

## Full Transcript

...
```

Recordings started in the same minute receive `-2`, `-3`, and so on instead
of overwriting an existing pair.

## Requirements

- macOS 15 or newer. Separate ScreenCaptureKit microphone output is used, so
  earlier releases are not supported.
- Apple Silicon for the included local build. Rebuild on an Intel Mac to
  produce an Intel-native app.
- Xcode Command Line Tools:

  ```bash
  xcode-select --install
  ```

- Node.js 22 or newer and npm, used to run the pinned Native SDK CLI.
- CMake and Git, used only while building the bundled `whisper.cpp` binary.
- An OpenAI API key with access to `gpt-5.6-luna`.

Create or manage an API key at the official
[OpenAI API keys page](https://platform.openai.com/api-keys). The same link is
available inside the app.

## Build and package

Install the pinned Vercel Native SDK CLI:

```bash
cd /path/to/meeting-notes
npm install
```

Prepare the bundled transcription assets:

```bash
npm run setup:whisper
```

This builds a static `whisper-cli` from pinned `whisper.cpp` v1.9.1 and
downloads the official multilingual medium model. The model is about 1.5 GB,
so the packaged app is correspondingly large. Running the command again reuses
the existing source, build, and model files. The setup script verifies the
exact source commit and model SHA-256 before building.

Run the checks:

```bash
npm run check
npm test
```

Run a development build:

```bash
npm run dev
```

Create the local macOS app:

```bash
npm run package:mac
```

`package:mac` automatically prepares Whisper if needed. The result is:

```text
release/Local Meeting Notes.app
```

The package contains the native app, Swift capture helper, `whisper-cli`,
medium model, and generated application icon. The packaging script adds the
privacy usage descriptions and applies a local signature with a stable
designated requirement. Move the app to `/Applications` before granting
permissions so macOS associates the grants with a stable path. The bundled
capture helper lives at `Contents/Helpers/meeting-notes-helper`, the standard
macOS location for an app-owned helper executable.

If a code-signing identity is installed, use it for the package instead:

```bash
MEETING_NOTES_CODESIGN_IDENTITY="Apple Development: Your Name (TEAMID)" npm run package:mac
```

This local build is not Developer ID signed or notarized. If Gatekeeper blocks
it, Control-click the app in Finder, choose **Open**, and confirm. Distribution
to other Macs should use your own Developer ID and notarization workflow. The
default local signature uses an identifier-only designated requirement so TCC
permissions survive rebuilds; use a certificate-backed identity on shared or
untrusted Macs.

## macOS permissions

Start a recording once so macOS can request access, then enable
**Local Meeting Notes** in:

1. **System Settings → Privacy & Security → Microphone**
2. **System Settings → Privacy & Security → Screen & System Audio Recording**

Some macOS releases label the second permission **System Audio Recording
Only**. Quit and reopen the app after changing either grant.

The app registers ScreenCaptureKit audio and microphone outputs but never a
screen-video output, so screen pixels are not written to disk. System audio
still uses macOS's standard screen-and-audio capture privacy permission.

Only record people who have consented, and follow the laws that apply in your
location.

## First-run setup and OpenAI Luna

On first launch, the onboarding screen explains the capture-to-note workflow
and asks for the OpenAI key needed to finish setup:

1. Choose **Get an OpenAI API Key** if you need to open the official keys page.
2. Paste the key into the API-key field.
3. Choose **Save & Continue**.

After onboarding, API-key management moves out of the recorder. Choose
**Settings…** from the menu-bar tray to replace or delete the saved key.

The key is sent to the bundled native helper over standard input, stored as a
generic password in macOS Keychain, and cleared from the UI after saving. It is
never written to a settings file. Avoid entering it while screen sharing.

The app uses the OpenAI Responses API with model `gpt-5.6-luna`, low reasoning
effort, and `store: false`. It uses an ephemeral URL session with client-side
caching and cookies disabled, and sends the complete transcript to OpenAI.
Audio remains local, and the app has no cloud database or sync service; your
OpenAI account's data controls and retention policy still apply.

If summary generation fails, the app still saves the audio and a Markdown note
containing the full local transcript plus a clear failure summary.

## Use the tray app

- **Start Recording** is available in the main window and menu-bar item.
- **Settings…** opens the dedicated API-key settings window.
- During capture, the menu-bar title changes from `MN` to `REC mm:ss`.
- **Stop Recording** finalizes the `.wav`, runs bundled Whisper transcription,
  calls OpenAI Luna, and writes the Markdown note.
- Closing the window hides it; the menu-bar item keeps the app running.
- Choosing Quit during recording requests a graceful stop and waits for the
  current note to be saved.

Do not force-quit while recording. The app uses a stop sentinel so
ScreenCaptureKit and AVFoundation can finalize the audio before capture exits.

## Privacy and offline behavior

| Data | Location or destination |
| --- | --- |
| Retained audio and Markdown | `~/MeetingNotes` |
| Temporary tracks, Whisper WAV, transcript, summary | `~/MeetingNotes`; removed after successful assembly |
| OpenAI API key | macOS Keychain |
| Transcript during summarization | OpenAI Responses API |

Recording, native audio processing, and Whisper transcription work without an
internet connection after the app is packaged. Summary generation requires
OpenAI and therefore requires a network connection. Local-language-model
support is intentionally not included.

The code contains no analytics SDK, crash reporter, update service, login,
remote database, or background upload. Its only normal remote request is the
explicit transcript summarization call to OpenAI.

## Troubleshooting

### Permission denied

Confirm both privacy entries are enabled, quit the app completely from its tray
menu, and reopen it. Earlier local packages used changing ad-hoc code identities.
If System Settings shows an old enabled entry but macOS still asks, remove that
entry with the minus button, reopen the newly packaged app, and grant access
once. Future local rebuilds keep the same designated requirement.

### Transcription fails

Use the packaged app from `release/Local Meeting Notes.app`; it contains both
`Contents/Resources/bin/whisper-cli` and
`Contents/Resources/models/ggml-medium.bin`. Re-run `npm run package:mac` if
either asset is absent. No Homebrew executable path is consulted at runtime.

### Summary fails

Confirm a key is saved, that the key can access `gpt-5.6-luna`, and that the
Mac is online. The full local transcript is still preserved in the note.
