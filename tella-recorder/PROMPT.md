# Codex build prompt: Tella Recorder

Build a production-quality native macOS desktop app called **Tella Recorder** in a new `tella-recorder/` subdirectory of the existing `marcusschiesser/desktop-apps` repository. It is an original, local-first replacement for the practical solo workflow of [Tella](https://canivibecodeit.com/tella): record a screen, camera, microphone, and system audio; make a few deliberate edits; render a polished video; and optionally publish it to infrastructure the user controls.

Personalize the product for experienced software engineers, open-source maintainers, independent builders, and technical creators similar to Marcus Schiesser. Do not add private or biographical information. Reflect only role-level preferences: fast keyboard-driven workflows, strong developer ergonomics, transparent architecture, reproducible output, local ownership of source recordings, optional user-owned hosting, and no mandatory SaaS account.

## Non-negotiable stack

- Use `@native-sdk/cli@0.8.1` from [vercel-labs/native](https://github.com/vercel-labs/native) and pin that exact version in `package.json` and the lockfile.
- Build the application UI with Native SDK `.native` markup and a TypeScript `Model` / `Msg` / `update` core.
- Do not use Electron, Tauri, React, a browser UI, or a WebView.
- Use a small Swift companion executable only for macOS functionality that Native SDK does not expose directly: ScreenCaptureKit capture, AVFoundation camera and microphone handling, system-audio capture, global shortcuts, permission status, and low-level media metadata.
- Use `ffmpeg` and `ffprobe` as explicit external tools for deterministic composition, trimming, poster-frame generation, and MP4 rendering. Invoke them with argument arrays, never through interpolated shell commands.
- Keep all recording, editing, and exporting local. Publishing must be optional and target infrastructure configured and owned by the user.

Before editing, inspect the repository and its root README. Stop rather than overwrite anything if `tella-recorder/` exists or if another directory already implements the same screen-recording product. Preserve every existing app and README entry.

## Product goal

The core loop is:

1. Select a display, window, or rectangular screen region.
2. Choose whether to include the camera, microphone, system audio, and cursor.
3. Start recording from the app or a configurable global shortcut.
4. Show an unobtrusive recording controller with elapsed time, active sources, pause, resume, and stop.
5. Review the recording, set in/out points, choose a small set of useful layouts, and render a polished MP4.
6. Reveal the local file, copy it, or optionally publish it to a configured user-owned host and copy the share URL.

This is not a general-purpose nonlinear editor. Build the shortest reliable path from technical walkthrough to shareable video.

## Functional requirements

### First-run setup and permissions

- Explain and request Screen Recording, Camera, and Microphone permissions only when the corresponding source is enabled.
- Detect denied, restricted, not-determined, and granted states and provide a direct route to the relevant System Settings pane when possible.
- Never start capture before explicit user action.
- Do not request Accessibility permission unless it is genuinely needed for the configured global shortcut implementation.
- Provide a diagnostics screen that reports Native SDK version, helper version, `ffmpeg`/`ffprobe` availability, permissions, configured output directory, and publishing configuration without exposing secrets.

### Capture

- Support full-display, individual-window, and selected-region capture through ScreenCaptureKit.
- Support camera as a separate track, microphone audio, system audio, and optional cursor capture.
- Default to 1080p at 30 fps; offer 4K only when the selected source and machine support it.
- Record source tracks separately when practical so layout changes do not require re-recording.
- Write recordings into a temporary project directory first, then atomically promote a successful project into the final library.
- Handle source disappearance, sleep/wake, device disconnects, permission revocation, low disk space, and helper crashes without corrupting completed media.
- Show honest state transitions: idle, preparing, countdown, recording, paused, finalizing, ready, rendering, publishing, completed, cancelled, and failed.
- Prevent duplicate recording, render, or publishing processes in model state.

### Project storage

Store projects under a configurable local directory, defaulting to:

`~/Movies/Tella Recorder/YYYY-MM-DD-HHMMSS-<safe-title>/`

Each project must contain:

- `project.json` with a versioned schema and relative paths
- original screen, camera, microphone, and system-audio tracks that were enabled
- generated thumbnails or filmstrip images
- `render.mp4` after a successful render
- `poster.jpg`
- `share/` containing the optional static share package

Never derive filesystem paths directly from untrusted titles. Sanitize names, prevent traversal, write through temporary files, and document backup and deletion behavior.

### Review and editing

- Show recording metadata, duration, dimensions, enabled tracks, and output size estimate.
- Provide in/out trim controls with frame-accurate timestamps where feasible.
- Generate a thumbnail strip for navigation.
- Provide these layouts:
  - screen only
  - screen with circular camera bubble in a selectable corner
  - screen and camera side by side
  - camera only
- Allow a solid or subtle gradient background, padding, corner radius, and camera size from a deliberately small preset set.
- Let the user mute microphone or system audio independently in the render.
- Provide a fast draft render and a final quality render.
- Prefer a Native SDK-supported native media surface if the current SDK exposes one. Otherwise generate a temporary preview clip and open it with the system video player. Do not introduce a WebView just to preview video.
- Do not implement arbitrary timeline tracks, transitions, captions, AI editing, animated zooms, or template marketplaces in the first version.

### Rendering

- Build `ffmpeg` arguments in typed, testable functions.
- Render H.264 MP4 with AAC audio and web-compatible pixel format, preserving aspect ratio.
- Support 1080p and 4K output presets, with a reasonable quality/size default.
- Compose camera overlays and backgrounds deterministically.
- Generate `poster.jpg` from a representative frame after the trim start.
- Stream render progress from `ffmpeg` into the Native SDK model and support cancellation.
- Keep original tracks unless the user explicitly deletes them.
- Validate the completed file with `ffprobe` before marking the render successful.

### Optional publishing

Publishing is disabled by default. Implement a narrow, transparent path for technical users who own a VPS or static host:

- Generate a self-contained share package with `index.html`, `render.mp4`, `poster.jpg`, Open Graph metadata, title, and optional author/byline.
- Support publishing through `rsync` over SSH to a configured destination and derive the final URL from an explicit base URL.
- Use the user's existing SSH configuration and keys. Never store private keys or passwords.
- Show the exact destination and files before the first publish.
- Provide a dry-run mode.
- Copy the final URL to the clipboard after success.
- Do not add accounts, proprietary cloud storage, analytics, telemetry, comments, or a hosted control plane.

## Native SDK requirements

- Use `src/app.native` for the interface and `src/core.ts` for deterministic state and orchestration.
- Define explicit `Model`, `Msg`, `initialModel`, and pure `update` logic. Derive display state rather than storing redundant booleans.
- Use keyed `Cmd.spawn` processes for the Swift capture helper, `ffmpeg`, `ffprobe`, preview opening, diagnostics, and publishing.
- Use newline-delimited JSON between the TypeScript core and Swift helper. Version the protocol and reject malformed messages safely.
- Route helper stdout/stderr into typed messages. Never parse human-oriented log text as state.
- Use Native SDK native controls, dialogs, menus, keyboard shortcuts, progress indicators, scroll containers, and accessibility labels.
- Keep the layout useful at the minimum window size and follow system light/dark appearance.
- Add a compact tray/menu-bar entry only if supported by the pinned SDK; otherwise keep the first version as a normal native window and document the limitation honestly.
- Use `native check`, `native dev --core`, `native build`, and Native SDK automation tooling where applicable.
- The shipped binary must not contain a browser, WebView, or JavaScript runtime.

## Architecture

Keep responsibilities clear:

- Native SDK TypeScript core: state machine, validation, process orchestration, persistence commands, progress, and error presentation.
- `.native` views: presentation and event dispatch only.
- Swift helper: capture devices, ScreenCaptureKit sessions, permission queries, global shortcut events, and media-track lifecycle.
- Media module: typed `ffmpeg`/`ffprobe` command construction and progress parsing.
- Project module: schema migration, safe paths, atomic writes, and library discovery.
- Publisher module: static share package generation, dry run, `rsync`, and final URL calculation.

Prefer a small number of explicit modules over a framework-like abstraction layer.

## Safety, privacy, and reliability

- No accounts, telemetry, analytics, crash uploads, hidden network calls, or automatic cloud sync.
- Never record unless the user visibly started a session.
- Display a persistent recording indicator while capture is active.
- Do not record protected or unavailable content; surface the system failure clearly.
- Never execute user-entered strings through a shell.
- Treat project metadata as untrusted when reopening existing projects.
- Use conservative process and file permissions.
- Do not silently install `ffmpeg`, download binaries, or modify shell profiles.
- Include an honest limitations section covering DRM/protected windows, platform scope, performance, unsupported codecs, and the difference between this focused tool and Tella's cloud editor and hosting.

## Testing and validation

- Add unit tests for the TypeScript update state machine, validation, safe project naming, render settings, publishing URL construction, and duplicate-process prevention.
- Add Swift tests for protocol decoding, permission-state mapping, capture configuration validation, and safe project paths. Hardware-dependent capture tests may be opt-in, but pure logic must run in CI.
- Add media tests that generate synthetic video and audio with `ffmpeg`, trim and compose them, then assert duration, dimensions, streams, poster generation, and non-empty output through `ffprobe`.
- Add a full-loop mock-helper mode so Native SDK automation can exercise setup, recording state, stop, review, render progress, success, failure, and cancellation without requiring real screen permissions.
- Add at least one deterministic `native automate` smoke scenario or the equivalent current Native SDK automation flow.
- Add a path-scoped GitHub Actions workflow on a macOS runner that installs dependencies and `ffmpeg`, then runs all tests, `native check`, the mock-helper automation test, and `native build`.
- Provide scripts for development, core checks, tests, helper build, diagnostics, mock mode, and release build.

## Documentation

Write a concise README that includes:

- the source inspiration and link to the Can I Vibecode It Tella page
- what the app deliberately replaces and what it does not
- prerequisites and exact setup commands
- macOS permission instructions
- architecture and local data layout
- `ffmpeg` installation and verification
- recording, rendering, and optional publishing workflows
- privacy, backup, deletion, troubleshooting, and limitations
- exact validation commands and expected outputs

Do not use Tella's name, logo, screenshots, code, or proprietary assets inside the product. `Tella Recorder` is only the repository working title; choose a distinct user-facing product name before shipping.

## Completion contract

Do not stop at scaffolding. Implement the working app, run every available check, fix failures, and report the exact commands and results. Confirm that no existing app or directory was overwritten or duplicated. Link the app from the repository root README with a red X until it has been manually validated, include the Can I Vibecode It source link on the same line, commit all changes, and push them to the repository's default branch.
