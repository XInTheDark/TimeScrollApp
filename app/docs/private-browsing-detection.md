# Private browser window detection

Everything lives in `TimeScrollDev/PrivateBrowsing/`. Detection is best effort: no public macOS API reports a private window, so it reads what browsers expose over Accessibility.

## Parts

| File | Job |
|---|---|
| `PrivateBrowsingCatalog` | Which browsers are supported and which markers each one uses. |
| `PrivateBrowsingMarkers` | Hand-collected markers (Safari). |
| `PrivateBrowsingMarkers+Generated` | Chrome, Brave and Firefox markers, in every language. Do not edit by hand. |
| `PrivateWindowClassifier` | Pure logic: evidence in, verdict out. |
| `PrivateWindowEvidenceReader` | The only code that talks to browsers. |
| `PrivateWindowTracker` | Decides what capture may see, and when to check windows. |
| `PrivateWindowFilterPlan` | Turns verdicts into a ScreenCaptureKit filter. |

## Rules

- A private verdict is never downgraded. A dialog can replace the title of a private window.
- No marker means "no marker found", not "proven normal".
- If detection cannot decide, frames resume after a short grace period. A detection failure must not stop capture.
- Browser popups are hidden while their browser has a private window, because a popup has no marker to show which window owns it.
- Never log window titles.

## Common changes

**A marker changed or a language was added:** re-run the generator with Chrome and Brave installed, then run `PrivateWindowClassifierTests`.

```bash
git clone --depth 1 https://github.com/mozilla-l10n/firefox-l10n.git /tmp/firefox-l10n
scripts/generate_private_browsing_markers.py --firefox-l10n /tmp/firefox-l10n
```

**A new browser:** add a profile to `PrivateBrowsingCatalog` and a title case to `PrivateWindowClassifierTests`. Mark it `.liveTested` only after reading the title of a real private window.

**A new kind of signal:** add a field to `PrivateWindowEvidence`, read it in the evidence reader, and decide it in the classifier. The tracker and capture code do not change.

## Status

| Browser | Status |
|---|---|
| Chrome, Brave, Zen | Marker tested on a live private window, on a blank page and a real page, in English |
| Firefox | Marker tested on a live private window in English; real page load not confirmed. Always-private mode may show no marker |
| Safari | Tested on Safari 27.2 in English on the Start Page. Swedish comes from a reported probe; other languages are missing |
| Edge, Arc, Vivaldi, Opera | Not tested: markers are expected from Chromium |
