# Codex build prompt: Site Spider

Build a production-quality native macOS desktop app called **Site Spider** in a new `site-spider/` subdirectory of the existing `marcusschiesser/desktop-apps` repository. It replaces the practical local-audit loop of Screaming Frog SEO Spider for software engineers, independent builders, and technical site owners. Do not include personal information about Marcus Schiesser; personalize only through public, role-level preferences: local-first software, strong developer ergonomics, transparent architecture, reproducible outputs, keyboard-friendly workflows, and no unnecessary SaaS dependency.

Use the current stable version of `@native-sdk/cli` from `https://github.com/vercel-labs/native`. The interface must use Native SDK `.native` markup and a TypeScript model/message/update core. Do not use Electron, Tauri, a browser UI, a WebView, React, or a hosted backend. Put network crawling and report generation in a small dependency-light companion executable that the Native SDK core starts through `Cmd.spawn`; Go is preferred because it produces a single portable binary and makes crawler tests straightforward.

Before editing, inspect the repository. Continue only in the current `site-spider/` directory created for this task; stop if a separate Screaming Frog replacement already exists. Preserve every existing app and root README entry.

## Product goal

The core loop is:

1. The user enters a URL for a site they own or are explicitly authorized to audit.
2. The app requires a visible permission acknowledgement before enabling the crawl.
3. The user chooses a URL cap and starts a local, same-origin crawl.
4. The app shows clear idle, validation, running, cancelled, failed, and completed states.
5. The crawler produces a reproducible raw CSV and a self-contained HTML report with prioritized issues, evidence, affected URLs, severity, and concrete remediation guidance.
6. The user can open the latest report from the desktop app.

## Functional requirements

- Accept only `http://` and `https://` start URLs with a hostname.
- Crawl only the normalized same origin; remove URL fragments and avoid duplicate URLs.
- Require an explicit `--permission-acknowledged` signal in the companion executable as well as the UI acknowledgement.
- Respect `robots.txt`, `nofollow`, redirects, canonical URLs, and a conservative request delay.
- Use a configurable URL cap with useful presets such as 25, 100, and 250 pages.
- Set a descriptive user agent and reasonable request/body limits and timeouts.
- Gracefully handle invalid URLs, DNS/TLS failures, non-HTML responses, redirect loops, cancellation, and partial crawl failures.
- Collect at least: requested URL, final URL, HTTP status, content type, response time, redirect count, title, meta description, H1 count, canonical, robots directives, noindex/nofollow, internal/external link counts, image count, missing-alt count, JSON-LD presence, and visible-text word count.
- Detect at least: fetch failures, 4xx/5xx URLs, redirect chains, missing/long/duplicate titles, missing/duplicate descriptions, missing/multiple H1s, missing canonicals, missing image alt text, and conflicting indexability signals.
- Export `crawl.csv` plus a standalone `report.html` under a safe application-controlled timestamped directory. Never derive output filenames directly from untrusted page content.
- Store all user data locally. Document the exact data location, backup, and deletion steps.
- Do not require secrets. If future optional integrations need secrets, keep them in `.env`, provide `.env.example`, and never commit credentials.

## Native SDK requirements

- Use a deterministic TypeScript `Model`, `Msg`, `initialModel`, and `update` function.
- Use `@native-sdk/core/text` for the controlled URL input rather than ad hoc string mutation.
- Use `Cmd.spawn` for crawl, cancellation, self-test, and opening the report; keep process keys unique and prevent duplicate in-flight crawls in model state.
- Use native panels, inputs, buttons, badges, scroll containers, separators, and accessibility labels.
- Make the layout useful at the minimum window size and follow the system appearance.
- Keep the binary free of a WebView and JavaScript runtime.
- Pin the Native SDK CLI version in `package.json`.

## Engineering requirements

- Keep the companion crawler free of third-party dependencies unless a dependency is clearly justified.
- Separate crawling, HTML inspection, issue detection, and report writing into testable functions.
- Add focused unit tests for URL validation, robots rules, same-origin/no-follow behavior, issue detection, and output generation.
- Add one end-to-end self-test using a local in-process HTTP server. It must crawl several pages, include a broken URL and duplicate metadata, respect robots/no-follow, and verify non-empty CSV and HTML output.
- Add scripts for helper build, development, validation, tests, and release build.
- Add a path-scoped GitHub Actions workflow that installs Node and Go, runs the full test suite, and builds the native app.
- Write a concise README covering setup, architecture, permissions, report location, privacy, backup, limitations, and exact validation commands.
- Link the source Can I Vibecode It page in the app README and link the new app from the repository root README.

## Deliberate non-goals

Do not crawl sites without permission. Do not implement a hosted control plane, accounts, billing, telemetry, analytics, cloud storage, backlink/keyword datasets, production-site modifications, or fake web-scale capabilities. JavaScript rendering, authenticated sessions, custom extraction rules, sitemaps, and very large crawls may be documented as future work, but the first implementation must remain honest, local, fast to understand, and fully testable.

## Completion contract

Do not stop at scaffolding. Run all available checks, fix failures, and report the exact commands and results. Confirm that no existing app was overwritten or duplicated. Commit all source files and the root README change in one focused commit and push it to the repository's default branch.
