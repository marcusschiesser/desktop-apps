# Site Spider

A local-first native desktop replacement for the core audit loop of [Screaming Frog SEO Spider](https://canivibecodeit.com/screaming-frog-seo-spider), built with [Vercel Native SDK](https://github.com/vercel-labs/native).

It is deliberately aimed at software engineers, independent builders, and technical site owners who want a fast, reproducible audit without an account, hosted control plane, or web-scale SEO dataset.

## What it does

- Requires an explicit acknowledgement that you own the site or have permission to crawl it.
- Crawls same-origin HTTP(S) pages with a configurable cap of 25, 100, or 250 URLs.
- Respects `robots.txt`, `nofollow`, redirects, and a conservative request delay.
- Collects status, content type, title, description, H1 count, canonical, robots directives, links, images, structured-data presence, visible-text word count, and response timing.
- Flags broken URLs, redirect chains, missing or duplicate metadata, heading issues, missing canonicals, missing image alt text, and indexability conflicts.
- Writes a raw `crawl.csv` and a self-contained prioritized `report.html` under `data/reports/<timestamp>/`.
- Keeps all crawl data on the local machine.

## Requirements

- macOS
- Node.js 22+
- Go 1.23+

## Run

```bash
npm install
npm run dev
```

The `dev` command builds the Go companion helper and opens the Native SDK app.

For a release build:

```bash
npm run build
```

## Validate

```bash
npm test
```

This runs focused Go unit tests, compiles the helper, executes a full crawl against an in-process test site, verifies the generated CSV and HTML report, and runs `native check` against the TypeScript core and `.native` view.

The helper can also be exercised directly:

```bash
npm run helper
assets/bin/seo-spider-helper self-test
assets/bin/seo-spider-helper crawl https://example.com 25 --permission-acknowledged
```

## Architecture

- `src/app.native` — native desktop interface, controls, status, and accessibility labels.
- `src/core.ts` — deterministic model/message/update loop and process effects.
- `helper/` — dependency-free Go crawler and report generator.
- `scripts/build-helper.sh` — builds the companion binary into `assets/bin/`.
- `PROMPT.md` — the Codex-optimized build specification derived from the original Can I Vibecode It prompt.

Native SDK renders the UI directly without Electron, a browser runtime, or a WebView. The Go helper owns network and filesystem work so the UI core stays small and testable.

## Data, privacy, and backup

All generated data lives under `data/reports/`. Copy that directory to back up or move audits. Delete it to remove all crawl data. The app has no accounts, analytics, telemetry, billing, or remote storage.

## Deliberate boundaries

This focused MVP does not execute JavaScript, crawl sites without permission, use backlink or keyword datasets, manage authentication-heavy sites, or make changes to production websites. Those are meaningful parts of the commercial product's moat rather than features to fake badly.
