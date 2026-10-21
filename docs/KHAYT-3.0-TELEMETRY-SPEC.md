# Opt-in telemetry & error reporting — spec

**Scope:** Add **privacy-preserving** crash/error reporting and **minimal, anonymized** usage diagnostics to Khayt. Today the app sends nothing — errors only land in `console.error` (e.g. `main.js` hub IPC handlers; `renderer/shell.js` `toast(…, 'error')` surfaces) and are lost on quit. This adds an **optional** outbound channel so a growing platform can find crashes before users report them. Implements [roadmap](./KHAYT-3.0-ROADMAP.md); upholds [security model](./KHAYT-3.0-SECURITY-MODEL.md) §1.1 ("Cloud is optional… No telemetry, no silent upload").

**Governing principle:** **Off by default. No PII ever. Transparent.** Telemetry is *cloud-optional* — it has its **own** endpoint and consent, independent of Khayt Cloud, online intake (`onlineEnabled`), and the LAN server. With everything off, the app is fully functional and emits nothing. The contract is the same as [AI-SPEC](./KHAYT-3.0-AI-SPEC.md): the system never sends shop data, never finalizes anything silently, and the owner can see and revoke at any moment.

---

## 1. What's collected (only after explicit opt-in)

Two **separately consented** streams. Each is an explicit allowlist — anything not listed is dropped.

**A. Crash / error reports** (consent: `telemetry.crashOptIn`)
- Scrubbed exception **stack trace** (frame functions + relative module paths only — see §4).
- Error class/name and a scrubbed one-line message.
- App version (`app.getVersion()`), Electron/Chromium version, OS family + major version (e.g. `macOS 14`, not build/serial).
- Process origin: `main` vs `renderer`, and the crash type (`uncaughtException`, `unhandledRejection`, `render-process-gone`, renderer error boundary).
- **On the native Mac app**, three sources feed this stream: failures of the shared rules engine, the note `LastWords` leaves after an uncaught Objective-C exception, and the crash reports macOS hands the app about its own crashes (MetricKit `MXCrashDiagnostic`, `NativeCrashes.swift`). The last carries only the Mach exception, the signal, the build number that crashed, the system's termination reason, and the crashing thread's frames as `binary +0xoffset`. All three go through the same scrubber, and only with `crashOptIn`.
- Anonymized **install id** (§5), coarse locale (`en`/`ar`), app channel (stable/beta — mirrors `betaUpdates`).

**B. Coarse usage counters** (consent: `telemetry.usageOptIn`) — **counts and enums only, never content.** Allowlist:
- Feature reached (enum: e.g. `quote_created`, `invoice_exported`, `ai_extract_used`, `backup_run`, `update_installed`) — incremented, never with the order/client/amount.
- Coarse environment flags: `mode` (simple/professional), `businessType` (solo/shop/farm/b2b), VAT on/off, ZATCA on/off, online/LAN on/off — booleans/enums already in `defaultSettings()`.
- Session count and coarse app-version-on-launch. No timestamps finer than the day; no per-action sequence.

**C. The anonymous install count** (no consent; ON by default with an off switch — decided 21 October 2026, the one exception to "off by default"). Once a UTC day, `POST /v1/active` with exactly six fields: `platform` (mac/win/linux/ios), `channel`, `version`, `firstThisWeek`, `firstThisMonth`, `firstEver`. No install id, no shop, no IP kept; the cloud keeps only daily counters (khayt-cloud #123, `docs/api-contract.md` "Active-install count"), 400 days. The switch, "Count this install (anonymous)", is per install and lives on the machine, never in the book. The rules are `ActiveCount` in KhaytCore (Mac and iPhone) and the desktop's sender. Described at khaytapp.com/privacy `#active-count-en`; the policy's wording is the authority.

## 2. NEVER collected (hard invariant)

No shop business data of any kind: **no** orders, clients, customer PII (names, phone, email, address), **no** financials (prices, margins, revenue, IBAN), **no** inventory/filament data, **no** file contents (STL/photos/PDFs), **no** secrets (API keys, PINs, tokens, SMTP/webhook secrets, ZATCA CSID/PCSID), **no** free-text the user typed, **no** raw file paths, **no** IP-derived geolocation beyond country (PDPL residency). Maps to security-model §3 ("no PII/line-items/margins") and the redaction surface already enumerated in `renderer/store.js → redactSettingsForExport()`. The **user id is never sent** — only the rotating install id (§5).

---

## 3. Consent & control UX

Streams A and B below. Stream C (§1C) is the one exception: sent without asking, switched off in Settings.

Lives in **Settings → Privacy** (`renderer/settings.js`), persisted in `defaultSettings()` (`renderer/app-state.js`) under a new `telemetry` object — defaulting **all false**, alongside existing opt-ins like `betaUpdates` and `quoteFollowUp.enabled`:

```js
telemetry: { crashOptIn: false, usageOptIn: false, installId: '', consentAt: '' }
```

- **First run / upgrade:** never auto-enabled and no nag. A single passive card explains the option; default stays off. It is asked once per computer, after the first-run setup, only of someone who may change Settings, and either answer puts it away for good (desktop: `renderTelemetryAsk` in `renderer/settings.js`; Mac: `TelemetryCard.swift`).
- **Two toggles**, separately consented (crash vs usage) — a user can share crashes but not usage. Saved via the existing `saveSettingsFromPanel()` checkbox pattern.
- **"View what's collected":** a modal (reuse `shell.js` modal) renders the *exact* last/next payload that would be sent, post-scrub, as readable JSON. No hidden fields.
- **Opt out anytime:** unchecking sets the flag false, **flushes and deletes** the local queue immediately (§7), and stops all collection that session — no restart required.
- **Consent timestamp** (`consentAt`) recorded for audit (security-model §3 "every read audited"); cleared on opt-out.

## 4. Scrubbing pipeline (`lib/telemetry-scrub.js`, runs before anything leaves the device)

Every payload passes through the scrubber; **unscrubbed sends are impossible by construction** (transport only accepts scrubber output). Reuses the project's existing redaction vocabulary:
1. **Paths:** replace any absolute path or `app.getPath('userData')` prefix with `<userData>`; strip usernames/home dirs from stack frames; keep only the module basename + line.
2. **Secrets:** apply the `STORE_SECRET_MASK` (`__KHAYT_MASKED__`) ruleset from `store.js`/`store-io.js` — any value matching apiKey/smtpPassword/botToken/secret/pin/token/csid/pcsid key shapes is masked.
3. **PII regexes:** drop email-like, phone-like (incl. `+9665…`), IBAN-like, and long-digit runs (card/CR/VAT) from messages and frames → replaced with `<redacted>`.
4. **Free text:** error messages truncated to a fixed cap; usage counters carry **no** string payload at all (enum + integer only).
5. **Allowlist gate:** the final object is built field-by-field from the §1 allowlist; unknown keys are never copied through.

---

## 5. Transport & storage

- **Separate, optional endpoint** — its own HTTPS URL, distinct from Khayt Cloud and from `lib/updater.js`'s GitHub releases feed. It **piggybacks the updater's trust model** (pinned HTTPS, no credentials, fails closed/silent) but is independently toggled; updater works with telemetry off and vice-versa.
- **Anonymized install id:** random UUID generated once on opt-in, stored in `telemetry.installId`. Rotates on full wipe (`hub:request-full-wipe`). It is **not** a user/account id and cannot be joined to a person.
- **Batching:** events queued in `userData/telemetry-queue.json`, flushed on a low-frequency timer and on graceful quit. Best-effort `POST` of a batch; non-2xx or offline → keep queued (mirrors `online.js` offline-aware behavior; respects `navigator.onLine`).
- **Retention:** server-side short retention (e.g. 90 days) then aggregate-only; documented in `privacy.html`. No durable per-install history.

## 6. Privacy / PDPL alignment

- **Data minimization (PDPL):** collect only the §1 allowlist; everything else dropped at source — not filtered downstream.
- **Lawful basis = explicit consent**, separately for crash vs usage, revocable, timestamped (`consentAt`); withdrawal purges local data (§7).
- **Residency:** endpoint hosted in the **KSA region** option per security-model §5; only country-level coarse locale leaves, never IP-derived precise location.
- **Transparency / subject rights:** "View what's collected" + `privacy.html` satisfy the right to know; the rotating install id keeps data effectively non-identifying, easing erasure.

## 7. Integration points

- **`main.js`:** add `process.on('uncaughtException')` + `process.on('unhandledRejection')` and `app.on('render-process-gone')`/`child-process-gone` handlers that build a crash report → scrub → enqueue (gated on `crashOptIn`). Wrap existing hub-IPC `console.error` sites (e.g. `hub:load-store`, `hub:save-store`, `completePendingFullWipe`) to additionally enqueue a scrubbed error when opted in. **Never crash the app to report a crash.**
- **Renderer:** a global `window.addEventListener('error')` / `'unhandledrejection'` error boundary, plus a hook in `shell.js toast(…, 'error')` so surfaced errors can be counted. Renderer hands raw error to main over IPC; **scrubbing happens in main** (single trusted choke point), never in the renderer.

## 8. Edge cases

- **Offline queue cap:** queue bounded (e.g. ≤200 events / ≤1 MB); oldest dropped first — telemetry never grows unbounded or blocks the app.
- **Opt-out mid-session:** immediately stop collection, flush nothing new, **delete** `telemetry-queue.json`, clear `installId`/`consentAt`.
- **Crash storm / flapping:** dedupe identical scrubbed stacks within a window; rate-limit sends.
- **Scrubber throws:** drop the event (fail closed) — a malformed report is never sent rather than risk leaking raw data.
- **Telemetry endpoint down:** silent; no toast, no user-facing error, no retry spam.

## 9. Test plan & DoD

- **Off-by-default:** fresh install + upgraded store → `crashOptIn === false && usageOptIn === false`; assert **zero** outbound requests across a full session with both off (network spy on the telemetry URL).
- **No-PII fuzz:** feed crash/error payloads seeded with emails, phones (`+9665…`), IBANs, API keys, absolute paths, and store snapshots; assert scrubbed output contains none of them and matches the §1 allowlist exactly. This is the headline gate.
- **Allowlist enforcement:** unknown/extra fields injected upstream never appear in the sent payload.
- **Consent separation:** crash-on/usage-off sends only crash stream, and vice-versa.
- **Opt-out purge:** toggling off deletes the queue and clears `installId`/`consentAt` without restart.
- **Resilience:** offline → events queue and cap correctly; endpoint 5xx → app unaffected; scrubber throw → event dropped, app stable.
- **View-data parity:** the "View what's collected" modal byte-matches the next enqueued payload.

**DoD:** all of the above green; nothing leaves the device unless a stream is explicitly enabled; no shop data, PII, secrets, or raw paths ever appear in a sent payload; `privacy.html` and the changelog document the feature and its PDPL stance.
