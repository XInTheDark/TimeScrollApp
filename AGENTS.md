# TimeScroll – Contributor & Agent Guide

For anyone changing this code, human or AI agent. Follow it for every change. Where it says "the user", that is whoever you are working for.

This repository mirrors the maintainer's private repository (only `app/`). Accepted changes are ported there by hand and the author is credited. Open PRs against `main` anyway; keep them small and independent.

## What TimeScroll is
A local-first macOS app that records the screen (optionally microphone and system audio), makes it searchable, and lets the user scroll back through time. Everything stays on the machine. It runs all day in the background, so **CPU, power, memory and disk use are product features, not afterthoughts** (see Performance & power).

## How it fits together
- `Capture/` — ScreenCaptureKit streams, one per display. `FrameOutput` drops near-duplicate frames (luma-grid signature + hash), adapts its interval to activity, backs off under thermal pressure, then persists frames (HEVC segments via `HEVCVideoStore`, or HEIC/JPEG/PNG) and a database row. `AppState` owns the capture lifecycle.
- Text: `Accessibility/` reads window text and titles; `OCR/` + `Index/` run Vision OCR on background queues with a cooldown. Capture admission stays occupied until text processing releases the buffer, which bounds memory.
- `Storage/` — SQLite/SQLCipher `DB` (one extension file per concern, a writer queue plus a separate read connection), text index, media stores, compaction and retention.
- `Audio/` — microphone and system-audio recorders, silence detection, segments, WhisperKit transcription.
- `Search/`, `CoreSearch/`, `AI/` — query parsing, keyword search, embeddings (Apple NL, MobileCLIP, optional Ollama) with an ANN index. `SearchFacade` is shared by the app and the MCP helper.
- `Timeline/` — `TimelineModel` (loaded window of rows, selection), `TimelineBarView` (a custom AppKit view), stage views for screen and audio snapshots.
- `Security/` — the encrypted vault (SQLCipher + encrypted media). `Privacy/` has the locked and recovery UI.
- `MCP/` and `timescroll-mcp` — the Model Context Protocol server; the helper only forwards searches to the running app.
- `Settings/`, `Permissions/`, `App/` — preferences, permission prompts, app delegate, menu-bar item.

## Project structure
- `app/TimeScrollDev` — SwiftUI/AppKit app code.
- `app/TimeScrollDevTests` — unit tests (XCTest and Swift Testing); the test target is `TimeScrollTests`.
- `app/TimeScrollDevUITests` — XCUITest.
- `app/CoreSearch`, `app/CoreSearchTests` — shared search/embedding engine and its tests.
- `app/timescroll-mcp` — thin stdio MCP helper; it holds no data access or keys.
- `app/TimeScroll.xcodeproj` — Xcode project, shared scheme `TimeScroll`.

## Build and test commands
- Build (exact command): `xcodebuild -project app/TimeScroll.xcodeproj -scheme TimeScroll -configuration Debug -quiet -allowProvisioningUpdates build` (`-allowProvisioningUpdates` lets Xcode create or renew the Apple Development certificate; needs an Apple account in Xcode ▸ Settings ▸ Accounts).
- Always build after changing code, and fix every error and new warning.
- Focused tests: `xcodebuild -project app/TimeScroll.xcodeproj -scheme TimeScroll -quiet test -destination 'platform=macOS,arch=arm64' -only-testing:TimeScrollTests/<SuiteName>` (`arch=arm64` avoids the ambiguous-destination warning).
- Full suite: the same command without `-only-testing` and with `-destination 'platform=macOS'`. It is not fully maintained, so report unrelated failures; do not hide them.
- CI (`.github/workflows/ci.yml`, GitHub-hosted macOS): unsigned build, unit tests, the opt-in benchmark suites (run locally with `TEST_RUNNER_TIMESCROLL_BENCHMARKS=1`), and a launch check that samples idle CPU and memory (`scripts/ci/launch_smoke.sh`). It cannot grant Screen Recording or Accessibility, so capture and Direct mode on real apps still need a local check.
- Swift Testing gotcha: compare an `Int64?` in `#expect` against a wrapped literal (`== Int64(1_800_000)`); a bare `30 * 60 * 1000` can fail even when the printed values match.
- Do NOT launch the Debug build to check things. It shares its bundle id (`com.muzhen.TimeScroll`), data directory, vault and MCP socket with an installed TimeScroll, so a second instance can capture alongside it and write to the same database. Launch it only if the user asks, with any installed copy quit first.

## Testing standard
Test thoroughly by default, in proportion to how much the change can break.
- Never offer, suggest or drift into lighter testing yourself. Reduce testing only if the user explicitly says "do light testing". Then build, run only the suites that directly cover the change, and skip benchmarks and screenshots, and say so.
- Logic gets unit tests, including edge cases: empty data, one item, huge data, midnight and DST boundaries, locked vault, several displays, cancelled or racing async work. Keep them deterministic with minimal fixtures. Name files `FooTests.swift`. Prioritize `Search/`, `Storage/`, `Capture/` and parsers.
- Run the focused suites that cover every area you touched, not just your new tests.
- UI changes (below) and large features (see Performance & power) have extra requirements.
- Do not run XCUITest flows unless the user explicitly asks.
- Finish with an honest report: what you ran and its result, what you could not verify, and a short manual checklist for the user of what to check by hand (gestures, hover, focus, animation, real data).

### UI changes
You must look at your UI, not just compile it.
1. Build.
2. Render the changed view offscreen with synthetic data from a throwaway unit test: host it in an `NSWindow`, call `bitmapImageRepForCachingDisplay`, write a PNG, and read the PNG. Cover light and dark appearance, narrow and wide windows, and empty, loading, long-text and many-item states. A single screenshot is the minimum, not the target.
3. Inspect each image for clipping, overlap, truncation, misalignment, poor contrast and inconsistent spacing. Fix what you find and render again. Do not claim a UI works from the code alone.
4. Delete the throwaway test and revert anything you loosened to make it possible (for example a `private(set)`).
   - Tests are hosted inside the app, so they share its real `UserDefaults`. Never assign an `@AppStorage`/`UserDefaults`-backed property (for example `model.msPerPoint`) in a test or harness: it silently overwrites the user's own settings. If a value must be set, snapshot the preference keys before the run, compare after, and restore any that changed.
5. A still image cannot show drag, pinch, scroll, hover, focus or animation. List those in your manual checklist.

## Performance & power
CPU, power, memory and disk I/O must never regress. This app is always on.
- Prefer designs that cost nothing when nothing happens: react to events instead of polling, coalesce and debounce, reuse existing signals and queues, load only what is visible, bound every buffer, cache results, do work lazily.
- Treat these as hot paths and keep them cheap and allocation-light: the capture callback, OCR, database writes, timeline `draw`, mouse-move and hover handlers.
- Draw and scroll code runs every frame. Its cost must follow what is visible, not the size of the data: compute anything derived from the whole data set (tick plans, label text, measurements) once per layout, cache it, and draw only the visible slice. A per-frame loop over all snapshots with string formatting made scrolling visibly choppy (17.9 ms per frame against 12.3 ms before, on 30k snapshots).
- If you suspect a change costs more resources, first look for an alternative that lowers the cost, and try it yourself. Do not just ship the expensive version.
- If cost remains after that, put a clear **⚠️ Performance/power impact** note in the commit message and PR description: what runs, how often, on which thread, and the measured numbers.
- Any large or logically complex new feature (new background work, a new query over the whole database, anything per-frame or per-snapshot, new indexes or caches) must be benchmarked before and after on the same data, and the numbers reported. Measure with a large synthetic database (100k+ snapshots), `time`/signposts for latency, and Activity Monitor, `top -pid`, or Instruments (Time Profiler, Energy Log) for CPU, wake-ups and memory. No numbers, no merge.
- Measure first for anything that looks harmless but sits in a loop or on a timer.
- Keep the numbers in `docs/performance/`: one Markdown file per feature with the machine, macOS and Xcode versions, build flags, dataset and method, plus the raw benchmark output in `docs/performance/data/`.

## Coding style
- Swift 6, 2-space indentation. Types use UpperCamelCase; methods and properties lowerCamelCase. One primary type per file. Organize by feature folder.
- STRICT SRP RULE: every file has exactly one reason to change. This is the highest-priority design rule.
- Adding a feature never means appending new types to an existing file. A new view, controller, model, query set or calculation gets its own file (for example `Timeline/DayCalendar/`, `Storage/DB+DayActivity.swift`); the existing file only gains the small hook that uses it. Keep pure logic (calculations, formatting, layout math) apart from views so it can be unit-tested.
- File size is a smell, not the rule. A long file is fine only if it still has one reason to change. If it starts handling several domains, flows or UI sections, split it immediately.
- Do not hide SRP violations behind "utility" files, giant hooks or giant config objects.
- Concurrency: treat SwiftUI/ObservableObject state as `@MainActor`. Background work must not touch main-actor singletons directly.
- Match the surrounding code's naming, comment density and idiom.

## Swift specifics
- Do NOT read `SettingsStore.shared` from background threads. Snapshot via `UserDefaults` or pass a value-type config (`let d = UserDefaults.standard; let min = d.double(forKey: "settings.captureMinInterval")`).
- In `NSObject` subclasses, call `super.init()` before using `self`.
- For image contexts, combine `CGBitmapInfo` with `CGImageAlphaInfo` (avoid `premultipliedFirst` alone).
- Use atomic writes and `FileManager.default.replaceItemAt(_, withItemAt:)` (assign the result to `_`).
- Vault media loads must check shared lock state before loading and revalidate their access token before publishing. Cache clearing must invalidate in-flight results as well as both image and video caches.
- Never delete source media until its replacement is verified and all database references are committed. Interrupted vault migrations must retain a replayable journal; failed HEVC sealing must retain the live segment.
- Keep capture admission occupied until text processing releases its buffer. Do not enqueue unbounded capture-pool buffers for OCR or thermal cooldown.

## Pitfalls to avoid
- Changing a default, or removing or replacing an existing interaction, without saying so prominently in the PR. Keep the existing behavior unless the change is the point of the PR.
- Adding a new user-facing "mode" when an affordance in the existing UI can do the job.
- Laying out on unclamped or estimated geometry; space things using what is actually drawn.
- Comparing two different APIs' views of the same state (for example ScreenCaptureKit's display list against `CGGetActiveDisplayList`). Compare a source with itself.
- Handling only the happy path of capture: sleep and wake, `replayd` crashes, displays added or removed, locked vault, permissions revoked.
- Claiming something was tested when it was only compiled.

## Commits and PRs
- One concern per PR. Explain what changed and why, and call out any changed default, removed interaction or performance impact.
- State what you tested and how, and include screenshots for UI changes.

## MCP (Model Context Protocol)
- Helper binary: `/Applications/TimeScroll.app/Contents/Helpers/timescroll-mcp.app/Contents/MacOS/timescroll-mcp`; exposed as an MCP stdio server named `timescroll` (Settings ▸ MCP pane). CLI equivalent: `claude mcp add --transport stdio timescroll -- "/Applications/TimeScroll.app/Contents/Helpers/timescroll-mcp.app/Contents/MacOS/timescroll-mcp"`. Claude Desktop config: `~/Library/Application Support/Claude/claude_desktop_config.json`.
- Protocol: newline-delimited JSON-RPC 2.0 over stdin/stdout (`initialize`, `tools/list`, `tools/call`). `protocolVersion` is `2024-11-05`; advertised capability `tools.listChanged=false`.
- Tools: only `search_timescroll`. Input: `query` (string), `max_results` 1–100 (default 20), `include_images` (default false; base64 JPEGs in `content` for the first 10 results, `image_max_pixel` default 1024, max 2048), `date_range` `{from,to}` ISO8601, `text_only` (default false, enables AI mode when false), optional `apps` bundle-id filter. Output wraps results with `time`, `app`, `ocr_text`; errors set `isError=true` with a text message.
- Execution flow: `MCPMain` starts `MCPServer`, flushes stdout, and dispatches `server.run()` on a user-initiated queue while keeping `dispatchMain()` free for UI/MainActor work. Requests are decoded via `LineIO`/`RPCRequest`; notifications (`notifications/...` without id) are ignored.
- Search handling: `MCPServer` builds an `MCPBridge.SearchRequest` and `MCPBridgeClient` sends it over the Unix socket `~/Library/Application Support/TimeScrollShared/mcp-bridge.sock` (one JSON line each way), launching TimeScroll hidden if nothing is listening. In the app, `MCPBridgeServer` accepts only the current user's TimeScroll helper (`MCPBridgePeerVerifier`: same team signature, or the validly signed helper inside this bundle), refuses when `settings.mcpEnabled` is off or the vault is locked, and runs `SearchFacade.run(...)` (OCR limit 50k chars). Images are opt-in. Unknown tool or method returns JSON-RPC errors.
- Vault (v2): a 32-byte master secret (HKDF → SQLCipher key + X25519 media key pair) stored as a login-keychain generic password (`VaultKeychainStore`) and, sealed with the user's required recovery passphrase, in `Vault/vault-v2.json` (`VaultManifest`, which also holds the media public key so locked captures still encrypt). Unlock = LocalAuthentication then keychain; the recovery passphrase restores a missing keychain item. Keys live only in the app (`VaultKeys`).
- Logging: `MCPFileLogger` writes to `group.com.muzhen.TimeScroll.shared/Logs/timescroll-mcp.log`. Logging failures are swallowed to avoid breaking the MCP stream; stdout must remain clean JSON. Never log request or response bodies (queries, OCR text, images); log sizes, ids and timings only. The log self-truncates past 1 MB.
