# Feature-flag & phased rollout — Khayt 3.0

**Scope:** How the 3.0 features (sync, mobile, AI assist, portal, and the cross-cutting feature specs) ship **incrementally and safely** — behind flags, beta-gated, with per-feature kill switches — without breaking the **cloud-off baseline**. Implements the rollout discipline behind [the roadmap](./KHAYT-3.0-ROADMAP.md) §0/§4 and the AI spec's opt-in/off-by-default rule ([AI-SPEC](./KHAYT-3.0-AI-SPEC.md) §4). This is process + plumbing; it ships no user feature of its own.

> **Note:** This doc supersedes nothing in the roadmap; it formalizes the existing pattern (Settings toggles + `-beta` tags) into a stated strategy so every phase lands the same way.

---

## 1. Governing principle — local flags, off-by-default, no baseline drift

Three hard rules, in priority order:

1. **Flags are local.** The source of truth for *what's enabled* lives in `settings` (the same store object as everything else), not a remote flag service. A cloud-pushed flag source exists only when the user has **opted into Cloud** (§5), and even then it can only *disable*, never silently *enable* (§8).
2. **Off by default.** Every cloud/AI/online feature defaults to `false`/hidden, exactly as today: `onlineEnabled:false`, `lanApi.enabled:false`, `operatorLockEnabled:false`, `betaUpdates:false`, `mode:'simple'` (`renderer/app-state.js` defaultSettings). New 3.0 features follow the same default.
3. **No baseline drift.** *A flag in its OFF state must produce byte-for-byte the same behavior as if the feature's code did not exist.* The cloud-off, key-less, LAN-off desktop app is the contract surface; no flag may change it when the flag is off. This is the roadmap's "cloud is optional, forever" §0 promise expressed as a flag rule.

---

## 2. Flag taxonomy

Four kinds, deliberately distinct so they have different lifecycles and owners:

| Kind | Purpose | Who flips it | Default | Persistence |
|------|---------|--------------|---------|-------------|
| **Release flag** | Gate an in-progress feature until it's GA. Removed once GA. | Engineering (ships flipped on at GA) | off | local `settings` |
| **Ops / kill switch** | Disable a *shipped* feature fast when it misbehaves. **Permanent** — never removed. | User (local) or Cloud-push (if connected) | on (feature live) | local `settings`, overridable by Cloud-push |
| **Experiment / beta** | Expose a feature only on the beta channel. | User opt-in (`betaUpdates`) + release-flag default keyed to channel | off on stable | local `settings` + build channel |
| **Entitlement (`pro` / cloud-tier)** | Gate by plan, not by readiness. Already exists as `mode:'simple'`→`.pro-only` (`renderer/styles.css:3454`) and the `lanApi`/`onlineEnabled` toggles. | Plan/tier (local `mode`; later Cloud entitlement) | per plan | local `settings` (+ Cloud entitlement when connected) |

A single feature usually carries **two** flags: a release flag (does the code path exist for this user yet) **and** a kill switch (is it currently safe to run). They collapse into one only after the release flag is removed at GA — the kill switch survives.

---

## 3. Where flags live

- **Primary: local `settings`.** Add a namespaced `settings.flags` object to `defaultSettings` in `renderer/app-state.js`, e.g. `flags: { aiAssist:false, syncEngine:false, portal:false, ... }`. It rides the existing `settings` deep-merge (the `nested` list at `app-state.js:432`) so unknown/older keys merge forward safely on load, and it persists through the single `saveAll()` choke point like everything else.
- **Build channel (compile-time floor):** the `-beta` vs stable build (§7). The renderer reads the channel (same source as `settings.betaUpdates`/`hubAPI.setUpdateOptions`) to decide whether a beta-gated release flag is *eligible* to be on.
- **Optional Cloud-pushed flags (opt-in only):** when — and only when — the user has connected Khayt Cloud (Phase 1, `onlineEnabled`-style toggle), the desktop may *pull* a small flag document on sync. It is **kill-only**: it can force a flag OFF (remote kill switch, §6) but **cannot enable** a feature the local setting hasn't enabled. Not connected → never fetched, no network, no behavior change. This keeps §1.1 intact: local-first by default, remote is strictly opt-in and strictly subtractive.

Resolution order for "is feature X live?": `channelEligible(X) && localSetting(X) && entitled(X) && !remoteKill(X) && !localKill(X)`. If *any* term is false, the feature is fully inert (§1.3).

---

## 4. Mapping 3.0 features to flags

`channel: stable` = ships on by default at its GA; `beta` = visible only on the beta channel until promoted. All cloud/AI features are **off-by-default** regardless of channel until the user opts in.

| Feature (spec) | Flag (`settings.flags.*` unless noted) | Default | Channel at introduction |
|----------------|----------------------------------------|---------|--------------------------|
| Phase 0 change-stamper / delta format | `syncStamper` | off → **on at GA** (internal, no UI) | beta → stable |
| Sync Engine + `local` backend | `syncEngine` | off | beta |
| Cloud connect (Phase 1) | `onlineCloud` (+ existing `onlineEnabled` pattern) | off (opt-in) | beta |
| AI assist — quote-from-description | `aiAssist` (gated also by BYO key) | off (opt-in) | beta → stable |
| AI follow-ons (drafting, NL analytics, reorder) | `aiDrafting`, `aiAnalytics`, `aiReorder` | off | beta |
| Remote mobile (cloud mode) | `remoteMobile` | off | beta |
| Customer portal / storefront | `portal`, `storefront` | off | beta |
| Print-file/gcode, shipping, scheduling, QC, webcam, maintenance, marketing, accounting | one flag each, e.g. `printFiles`, `shipping`… | off → on at each GA | beta → stable |
| RBAC (extends operator-lock) | `rbac` (rides `operatorLockEnabled`) | off | beta |
| Audit log | `auditLog` | off → on at GA | beta → stable |
| Entitlement gate (existing) | `mode` (`simple`/`professional`) → `.pro-only` | `simple` | stable (already shipped) |

Cloud-independent features (AI, print-files, QC, scheduling, audit) can graduate to stable without any backend; Cloud-dependent ones (sync, mobile, portal) stay beta until their phase backend GAs.

---

## 5. Flag lifecycle: introduce → beta → GA → remove

1. **Introduce** — add the key to `defaultSettings.flags` (off), guard every code path behind the §3 resolver. With the flag off the diff is inert against the baseline (enforced by a test, §8).
2. **Beta** — set the flag eligible on the beta channel only; ship in a `-beta.N` prerelease (§7). Real users opt in via the beta channel; gather signal.
3. **GA** — flip the default on (for cloud-independent features) or expose the opt-in toggle (for cloud/AI features) on the stable channel. The **kill switch stays**.
4. **Remove the release flag** — once GA has been stable across ≥1 release, delete the *release* flag and its branches; the feature becomes unconditional code. Keep the **ops/kill switch** and any **entitlement** gate forever. Removal is a cleanup PR with the flag name in the title so it's auditable.

---

## 6. Kill switches

Every shipped feature keeps a permanent OFF path, even after its release flag is gone:

- **Local kill:** a `settings.flags.kill.<feature>` boolean (or reuse the feature's own opt-in toggle set to false). Flipping it OFF returns the feature to baseline behavior immediately — no restart beyond the normal settings re-render (`renderer/shell.js` mode-class pattern). This is how a user disables a misbehaving AI/sync/portal feature on their own machine, offline.
- **Cloud-pushed kill (opt-in, connected only):** the §3 remote flag document carries `kill.<feature>:true`. On the next sync pull (only if Cloud is connected) the desktop honors it, forcing the feature inert without an app update. **Subtractive only** — it can disable, never enable. Used to stop a feature that's breaking against the live backend (e.g. a portal/sync regression) before a patched build ships.
- **Server-side stop for cloud features:** any feature that *requires* Cloud (sync/mobile/portal) is additionally killable by the backend simply rejecting its calls — the client already degrades gracefully (roadmap §0 "no key / no connection → feature hides"), so a server-side disable is inherently safe.

Kill precedence: any kill (local or remote) wins over every enable. A killed feature is indistinguishable from a feature that was never built (§1.3).

---

## 7. Beta-channel mechanics (reuse `-beta` tags)

No new infrastructure — reuse the existing release flow:

- `node scripts/bump-version.js beta` produces `X.(minor+1).0-beta.1` and bumps `-beta.N` thereafter.
- `.github/workflows/release.yml` detects `-(beta|rc|alpha)` in the tag and marks the GitHub Release **prerelease** (`create-release` step).
- The desktop only offers prereleases to users who opted in: `settings.betaUpdates` → `hubAPI.setUpdateOptions({ allowBeta })` (`renderer/app-boot.js:361`, `settings.js:1228`). Stable users never see beta builds.
- **Tie flags to the channel:** a beta-channel build sets the channel floor so beta-gated release flags are *eligible*; the stable build makes them inert regardless of local setting. Thus "beta feature" = (beta build) ∧ (flag on) — a stable user cannot accidentally enable a beta-only feature.

CHANGELOG: each `-beta` entry lists which flags it introduces/promotes/removes, so the flag state of any release is reconstructable from `CHANGELOG.md`.

---

## 8. Testing flags (both states)

- **Baseline-equivalence test (mandatory per feature):** with the flag OFF, assert the app's observable behavior/state equals the pre-feature baseline — this is the §1.3 guard, mirroring the AI spec's "no-key → zero change to the app, assert" DoD.
- **Both states tested:** every feature path has a test with the flag ON and one with it OFF; CI runs the suite in the default (all-off) config and at least one all-on config.
- **Resolver tests:** the §3 precedence (channel ∧ local ∧ entitlement ∧ ¬kill) — including the *can't-enable-remotely* and *kill-always-wins* invariants.
- **Merge-forward test:** loading an older `store.json` with no `flags` object yields all-off defaults via the existing deep-merge.
- **Channel test:** beta-gated flag is inert on a stable build; eligible on a beta build.
- Mock all network/model calls (no live Cloud or Anthropic calls in tests), per AI-SPEC §7.

---

## 9. Edge cases

- **Flag combinations:** features must not assume a sibling flag is on (e.g. AI drafting must work whether or not sync is on). Each guard checks only its own resolver result; integration tests cover the realistic combos (AI-on/sync-off, sync-on/portal-off, etc.).
- **Downgrade:** a stable build run after a beta build must ignore beta-only flags left ON in `settings` (channel floor makes them inert) without erroring — never crash on an unknown/now-ineligible flag.
- **Flag drift (local vs Cloud-pushed):** local says ON, remote-kill says OFF → OFF wins (kill is subtractive, §6). Local OFF + remote ON is **impossible by design** (remote can't enable). If Cloud is disconnected, the remote document is discarded and only local flags apply — disconnecting Cloud can only *re-enable* a remotely-killed-but-locally-on feature, which is the intended "you're back in local control" behavior.
- **Stale remote flags:** remote flag doc carries a timestamp; if stale/unfetchable, fall back to local-only (never block on it). No-connection must equal local-only, always.
- **Entitlement loss (later, Cloud tier):** losing a paid tier disables the cloud-tier feature gracefully (hides like `.pro-only`); local data is untouched and the local/baseline features remain fully functional.

---

## 10. Definition of Done

- `settings.flags` exists in `defaultSettings`, deep-merges forward, persists through `saveAll()`; all 3.0 features routed through the §3 resolver.
- Every feature ships with both a release flag and a permanent kill switch; the §8 baseline-equivalence test passes (flag OFF ⇒ byte-for-byte baseline).
- Beta features are reachable only on `-beta` builds with `betaUpdates` on; stable users are unaffected.
- A misbehaving feature can be disabled (a) locally offline and (b) via Cloud-push when connected — kill always wins, and no flag, local or remote, can make the cloud-off baseline behave differently when its feature is off.
- Each release's flag transitions (introduce/promote/remove) are recorded in `CHANGELOG.md`.
