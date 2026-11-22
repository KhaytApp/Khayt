# Security & Bug Audit — Khayt

Audit date: 2026-06-05 (beta.2 hardening pass).

Automated checks: `npm test`, `npm run lint`, `npm audit` (0 vulnerabilities).

## Remediated (prior passes)

| Item | Fix |
|------|-----|
| Quote approval IDOR | `GET /order/:id/quote` requires valid `?token=` |
| Settings panel Save dead | `saveSettingsFromPanel()` wired |
| Settings save data loss | Preserves `onlineEnabled`, security, quote counters |
| Tunnel stale after LAN stop | Tunnel closes on LAN stop/restart |
| Printer `accessCode` leak | Masked independently of `apiKey` |
| iCal feed unauthenticated | `/calendar.ics?token=` with `calendarToken` |
| Survey export broken | Interactive HTML preserves scripts; `JSON.parse` for config |
| Start Tunnel form sync | `saveLanApiSettingsFromForm` + PIN from disk |
| Tunnel not restored on boot | Restores when `tunnelEnabled` after LAN start |
| LAN status UI stale | Live `getLanUrl()` reconciliation |
| Silent email/webhook failures | Warning toasts + `console.warn` |
| Intake session spam | Rate limit on session grants (40/hour/IP) |
| Machine secret index merge | ID-only merge |
| Unsafe URL sinks | `safeHttpUrl` / `safeImageSrc` in renderer |
| Keychain unavailable | Boot warning when OS encryption unavailable |

## Remediated (v2.4.0-beta.2)

| Item | Fix |
|------|-----|
| Printer webhook → owner PIN lockout | `isWebhookAuthLocked('printer')` compound key (isolated from owner PIN map) |
| LAN spool arbitrary fields | `pickLanSpoolFields()` allowlist on POST spool |
| Intake `referenceLink` scheme | `sanitizeLanHttpUrl()` — `http`/`https` only |
| LAN HTML missing headers | `setLanHtmlSecurityHeaders()` on customer HTML responses |
| Update flush skips validation | `normalizeStoreSnapshot()` before `encryptForDisk` on install flush |
| Confirm modal latent XSS | `promptTypeConfirmModal` always uses `escapeHtml(message)` |
| `safeJsonParse` prototype key | Strips `prototype` alongside `__proto__` / `constructor` |
| Timestamp ID collisions | `uniqueLanId()` with random suffix |
| PWA manifest quote escaping | Removed redundant `.replace` before `JSON.stringify` |
| Stable beta updater | `settings.betaUpdates` opt-in (default off) on stable **v2.3.3** and beta |

## Still open (lower priority)

| Severity | Item | Notes |
|----------|------|-------|
| Medium | Public intake on LAN/tunnel | Rate-limited; optional PIN/CAPTCHA if abuse occurs |
| Medium | Secrets plaintext without keychain | Warned on boot; full fail-closed deferred |
| Medium | Large preload bridge | Narrow IPC surface over time |
| Low | Import URL validation in store-validate | Shape-only import checks remain |
| Low | `hub:verify-operator-pin` operator enumeration | Distinct error codes; renderer-only IPC |
| Low | `data-i18n-html` latent sink | No usages; document if kept |

## Hardening in place

- Electron: `contextIsolation`, `nodeIntegration: false`, `sandbox: true`
- IPC guard on `hub:*` channels
- LAN owner PIN, brute-force lockout, constant-time compares
- Quote + calendar + tracking tokens on customer URLs
- Salla/Zid webhook HMAC + per-channel lockout keys
- Updater: stable ignores prereleases unless `betaUpdates` enabled

## Recommended next steps

1. HTTP integration tests for LAN routes (auth, rate limits, tokens)
2. Optional intake PIN when remote tunnel is enabled
3. Periodic `npm audit` + dependency bumps on release tags
