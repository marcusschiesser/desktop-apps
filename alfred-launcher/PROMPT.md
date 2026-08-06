# Codex build prompt: Forge Launcher

Build a production-quality native macOS desktop app with the working product name **Forge Launcher** in a new `alfred-launcher/` subdirectory of the existing `marcusschiesser/desktop-apps` repository. It is an original, local-first replacement for the practical solo workflow of [Alfred Powerpack](https://canivibecodeit.com/alfred-powerpack): open a global command palette, find apps and files, use snippets and clipboard history, and run a small set of trusted workflows without depending on an account or cloud service.

Design it for experienced software engineers, open-source maintainers, independent builders, and other technical users. Do not include private or biographical information about Marcus Schiesser. Reflect only broad role-level preferences: keyboard-first operation, low latency, transparent behavior, local data ownership, inspectable configuration, reproducible builds, strong diagnostics, and no mandatory SaaS account.

## Repository safety

Before changing anything:

1. Inspect the repository tree and root README.
2. Confirm that `alfred-launcher/` does not exist.
3. Search existing app directories and prompts for launchers, command palettes, clipboard managers, snippet tools, or Alfred-like workflows.
4. Stop without writing files if the new app would overwrite or materially duplicate an existing app.
5. Preserve every existing directory and README entry.

Do not rename or reorganize unrelated files.

## Non-negotiable stack

- Use [vercel-labs/native](https://github.com/vercel-labs/native) through `@native-sdk/cli@0.8.1`. Pin the exact version in `package.json` and the lockfile.
- Use the Native SDK default authoring model: declarative `.native` UI plus a TypeScript `Model`, `Msg`, `update`, commands, and subscriptions in `src/core.ts`.
- The shipped app must be compiled ahead of time and contain no browser, WebView, JavaScript runtime, or interpreter.
- Do not use Electron, Tauri, React, SwiftUI for the main UI, or a browser frontend.
- Use a focused Swift 6 companion executable only for macOS functionality not exposed cleanly by the pinned Native SDK: global hotkey registration, menu-bar integration, application discovery and launch, Spotlight-backed file search, clipboard observation, optional text insertion, login-item management, Keychain access, and permission status.
- Use SQLite through the Swift helper for durable local state. Keep schema ownership and migrations in one module.
- Communicate between the TypeScript core and Swift helper with versioned newline-delimited JSON over stdin/stdout. Treat stderr as diagnostics only, never as application state.
- Invoke executables with explicit argument arrays. Never build commands through shell-string interpolation.

At the start of implementation, run and read the current SDK guidance:

```bash
npx @native-sdk/cli@0.8.1 skills get core
npx @native-sdk/cli@0.8.1 skills get native-ui
npx @native-sdk/cli@0.8.1 skills get ts-core
npx @native-sdk/cli@0.8.1 skills get automation
```

Follow the pinned SDK rather than guessing APIs from older examples.

## Product goal

The core loop must be fast enough to become a daily habit:

1. Press a configurable global shortcut.
2. Type a query immediately, with the text field focused and no visible startup delay.
3. See ranked results from applications, recent files, configured folders, snippets, clipboard history, and trusted actions.
4. Use arrow keys to select a result and `Return` to execute it.
5. Hold or press a modifier to reveal alternative actions such as copy path, reveal in Finder, open in Terminal, or open in a configured editor.
6. Dismiss the window with `Escape`; preserve no query unless the user enables query history.

This is not an Alfred-compatible clone and not a general automation platform. Build a focused, secure launcher for one technical user.

## Functional requirements

### 1. Launcher window

- Register a configurable global shortcut that defaults to `Option+Space` and does not require Accessibility permission when a standard macOS hotkey API can handle it.
- Show a compact native command window centered near the top of the active display.
- Focus the query field immediately when opened.
- Keep the window responsive while providers search asynchronously.
- Support full keyboard navigation: up/down, page up/down, `Return`, alternate action modifier, `Escape`, and a shortcut to open settings.
- Display clear result type, primary label, secondary context, icon when available, and shortcut hint.
- Preserve stable selection while asynchronous providers update.
- Deduplicate equivalent results and use deterministic tie-breaking.
- Hide the launcher after a successful action unless the action intentionally keeps it open.
- Provide explicit empty, loading, partial-results, permission-required, recoverable-error, and no-results states.

### 2. Search providers

Implement a provider interface with cancellable queries, deadlines, result limits, stable IDs, and typed actions. Include these built-in providers:

#### Applications

- Discover installed macOS applications using supported workspace APIs.
- Match name, bundle identifier, aliases, and user-defined keywords.
- Launch the selected application.
- Provide alternate actions to reveal the application and copy its bundle identifier.

#### Files and folders

- Search Spotlight through `NSMetadataQuery` or the current supported macOS metadata API.
- Let users limit search to explicitly configured roots and common locations.
- Open a file with its default app.
- Provide alternate actions: reveal in Finder, copy path, open parent folder, open in configured editor, and open directory in configured terminal.
- Never create a second full-disk index when Spotlight is available.
- Handle unavailable or disabled Spotlight honestly and fall back to configured-folder filename search only.

#### Recent projects

- Let users register development roots such as folders containing Git repositories.
- Discover repositories incrementally and store only path, display name, last-opened time, and optional remote URL.
- Rank recent and frequently used repositories highly.
- Offer actions to open in the configured editor, open in Terminal, reveal in Finder, copy path, and copy remote URL.
- Read Git metadata safely without executing repository-controlled hooks or commands.

#### Snippets

- Store named snippets, keywords, plain text, and optional placeholders locally.
- Search snippets by title, keyword, and content preview.
- Default action copies text to the clipboard.
- Optional direct insertion may be enabled separately and must request Accessibility permission only at the moment the user enables it.
- Support simple deterministic placeholders such as current date, current time, clipboard text, and cursor position markers.
- Do not implement remote snippet sharing or executable template expressions.

#### Clipboard history

- Capture only text and file URLs by default. Images may be added only after the core implementation is complete and tested.
- Store history locally with configurable retention, item count, and maximum payload size.
- Deduplicate consecutive items.
- Ignore data marked transient or concealed by pasteboard conventions.
- Let the user exclude specific applications, pause capture, clear history, and disable the feature entirely.
- Never record clipboard contents while a configured password manager or excluded app is frontmost.
- Default action restores the item to the clipboard. Optional direct insertion follows the same just-in-time Accessibility rule as snippets.
- Show the source app only when macOS exposes it reliably; never infer or fabricate it.

#### Calculator and quick conversions

- Implement a small deterministic expression parser for arithmetic, percentages, parentheses, and a documented set of unit conversions.
- Do not evaluate JavaScript, Python, shell, AppleScript, or arbitrary code.
- Copy the result on `Return`.

### 3. Trusted workflows

Provide a deliberately narrow workflow system for commands the user authored or explicitly imported.

- Store workflows as local, versioned JSON or TOML manifests.
- A workflow declares a name, keywords, executable path or fixed built-in action, argument templates, working-directory rule, environment allowlist, timeout, and output policy.
- Execute a process directly with executable plus argument array; never through `/bin/sh -c` or another shell by default.
- Require an explicit per-workflow opt-in before shell execution is allowed at all, and show a persistent warning in settings.
- Treat placeholders as data, not syntax. Validate all substituted values.
- Show the exact executable, arguments, working directory, and permissions before first run and after a manifest changes.
- Add confirmation for destructive or privileged-looking actions.
- Cap runtime, stdout, stderr, and result size. Support cancellation and kill the full child process group.
- Never download, install, or auto-update workflows.
- Do not add a marketplace, remote registry, package manager, JavaScript plugins, or execution of untrusted repository code.

Include useful built-in developer actions that require no arbitrary scripts:

- open a repository in a configured editor
- open a directory in a configured terminal
- copy a file path or Git remote URL
- reveal a path in Finder
- open a URL
- create a new terminal window in a chosen directory
- search the current project's files through Spotlight

### 4. Ranking and learning

- Rank results locally using exact prefix, token prefix, fuzzy match, provider priority, recency, and frequency.
- Keep the scoring function deterministic and unit tested.
- Store usage statistics locally only.
- Let users reset learned ranking and disable usage learning.
- Do not use an embedding model, cloud API, or opaque AI ranking.
- Never let usage frequency overwhelm an exact match.

### 5. Settings and data controls

Provide one focused settings window with sections for:

- global shortcut
- enabled providers and provider priority
- search roots and repository roots
- configured editor and terminal
- clipboard retention and excluded applications
- snippets import/export
- trusted workflows and their permissions
- launch at login
- appearance and result count
- backup, restore, reset, and uninstall instructions
- diagnostics

Settings must validate paths and executables before saving. Store secrets only in the macOS Keychain, although the first release should not require any secrets.

### 6. Import and export

- Export settings, snippets, workflows, aliases, and provider configuration to a human-readable archive.
- Exclude clipboard history, usage history, secrets, caches, and machine-specific transient state by default.
- Preview exactly what will be exported or imported.
- Validate schema versions and reject traversal, symlinks that escape the extraction directory, malformed manifests, duplicate IDs, and oversized data.
- Import into a staging area and commit atomically only after full validation.

## Native SDK architecture

Use this layout unless current SDK scaffolding requires a small adjustment:

```text
alfred-launcher/
  app.zon
  package.json
  package-lock.json
  src/
    app.native
    core.ts
    model.ts
    messages.ts
    ranking.ts
    validation.ts
    workflow.ts
  helper/
    Package.swift
    Sources/ForgeHelper/
      main.swift
      Protocol.swift
      HotKeyService.swift
      AppSearchService.swift
      FileSearchService.swift
      ClipboardService.swift
      Database.swift
      WorkflowRunner.swift
      PermissionService.swift
      LoginItemService.swift
    Tests/ForgeHelperTests/
  tests/
  automation/
  README.md
```

Keep responsibilities strict:

- `.native` files: presentation, bindings, accessibility labels, and event dispatch only.
- TypeScript core: deterministic model, update logic, ranking, validation, provider orchestration, command lifecycle, and user-visible error mapping.
- Swift helper: macOS APIs, SQLite, process execution, hotkey events, clipboard observation, Spotlight, application launching, login item, and permission queries.
- Never parse human log lines into state. Every helper event must be typed JSON with a protocol version and request ID.
- Use keyed commands so stale query results, duplicate searches, repeated actions, and overlapping workflow runs can be cancelled or ignored safely.
- Derive display state from the model rather than storing redundant booleans.
- Keep provider result payloads bounded.

## Suggested model and protocol

Define an explicit TypeScript model containing at least:

- app lifecycle and helper connection state
- launcher visibility and active query
- monotonically increasing query generation
- enabled providers and pending provider requests
- result collection, ranking inputs, and selected stable ID
- action execution state
- permission state
- settings and validation errors
- clipboard capture state
- workflow confirmation state
- diagnostics and recoverable errors

Define typed messages for opening and closing the launcher, query changes, provider batches, provider completion, selection movement, action execution, permission changes, settings edits, helper restarts, clipboard events, workflow confirmation, cancellation, and failures.

The helper protocol must include:

- protocol negotiation and helper version
- request ID and query generation on all asynchronous search messages
- bounded result batches
- explicit cancellation
- structured errors with stable codes and safe user-facing messages
- permission status without prompting
- separate commands for prompting or opening System Settings
- clean shutdown and restart behavior

Reject unknown protocol versions and malformed messages without crashing.

## Privacy and security

- No accounts, telemetry, analytics, crash uploads, advertising, hidden network requests, or automatic update checks.
- No network access is required for normal use.
- Never capture clipboard content unless clipboard history is visibly enabled.
- Make paused clipboard capture obvious in the launcher and settings.
- Do not log queries, clipboard text, snippet bodies, file names, workflow arguments, environment values, or secrets.
- Redact sensitive values from diagnostics exports.
- Request permissions just in time and explain the exact feature that needs each permission.
- Prefer APIs that avoid Accessibility permission. Only request it for optional direct text insertion when the user enables that feature.
- Do not require Full Disk Access. Explain that inaccessible files will not appear.
- Validate every path received from persistence or import.
- Use atomic writes, restrictive file permissions, and SQLite transactions.
- Never follow untrusted symlinks during import, backup, or workflow working-directory resolution.
- Do not execute project-local binaries, hooks, scripts, or configuration merely because a repository was indexed.

## Performance targets

Measure and document these targets on a representative Mac:

- launcher window visible within 100 ms after a warm global-shortcut event
- query input remains responsive while providers run
- application results available within 50 ms from a warm cache
- first useful mixed results within 100 ms for common queries
- stale provider batches never replace results for a newer query
- idle CPU near zero when clipboard history is disabled
- bounded memory and database growth under configured retention limits

Do not fake timings. Report the machine, dataset size, method, and observed median/p95 values.

## Testing and validation

Add deterministic tests for:

- fuzzy matching, tokenization, ranking weights, tie-breaking, recency, frequency, and exact-match dominance
- query generations and stale-result rejection
- selection stability during asynchronous result updates
- provider cancellation and timeout behavior
- snippet placeholders and escaping
- clipboard deduplication, retention, size limits, exclusions, and concealed-item filtering
- safe path handling and import traversal rejection
- workflow manifest validation, executable/argument separation, environment allowlisting, timeout, output caps, and confirmation rules
- settings migration and SQLite migrations
- protocol decoding, version negotiation, malformed messages, and bounded batches
- duplicate command prevention and helper restart recovery

Add Swift tests for macOS-independent helper logic. Hardware- or permission-dependent tests may be opt-in, but pure logic must run in CI.

Create a mock-helper mode that returns deterministic applications, files, repositories, snippets, clipboard items, permission states, and workflow outcomes. Use it for Native SDK automation tests covering:

1. open launcher
2. type query
3. receive mixed asynchronous results
4. navigate and execute an action
5. open an alternate action
6. show no-results and provider-error states
7. restore a clipboard item
8. execute and cancel a trusted workflow
9. reject a changed workflow until reconfirmed
10. edit settings and restart cleanly

Use the current Native SDK automation interface discovered from `native skills get automation`. Add at least one deterministic smoke test that drives the compiled app without screen scraping when semantic automation data is available.

Add a path-scoped GitHub Actions workflow on a macOS runner that:

- installs the exact Node and Native SDK dependencies
- builds and tests the Swift helper
- runs TypeScript/core tests
- runs `native check`
- runs mock-helper automation
- runs `native build`
- confirms the packaged binary does not contain a WebView or bundled JS runtime

## Documentation

Write a concise README containing:

- the product scope and the [Can I Vibecode It Alfred Powerpack source](https://canivibecodeit.com/alfred-powerpack)
- what the app replaces and what it deliberately does not replace
- prerequisites and exact setup commands
- Native SDK and Swift helper architecture
- permissions and why each is optional or required
- local data locations and SQLite schema ownership
- clipboard privacy behavior and exclusions
- trusted workflow security model
- backup, restore, reset, and uninstall steps
- troubleshooting and diagnostics
- validation commands and actual observed results
- known limitations compared with Alfred's years of macOS integration and workflow ecosystem

Do not use Alfred's name, logo, screenshots, code, workflow files, or proprietary assets inside the shipped product. `Forge Launcher` is an original working name and may be changed before release.

## Completion contract

Do not stop at scaffolding. Implement the working app and the Swift helper, exercise the real core loop on macOS, run every available check, fix failures, and record the exact commands and outcomes. Do not claim tests passed unless they were actually executed.

At completion:

1. Confirm no existing app or directory was overwritten or duplicated.
2. Confirm all user data is local by default and no hidden network call exists.
3. Confirm the global shortcut, application search, file search, snippets, clipboard history, and at least one trusted workflow work end to end.
4. Confirm permission-denied and helper-failure states are recoverable.
5. Link the app from the repository root README with a red X until manually validated, with the Can I Vibecode It source link on the same line.
6. Commit all files and push them to the repository's default branch.
7. Report the exact validation commands, observed results, limitations, and repository link.
