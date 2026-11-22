# Khayt 3.0 — testing strategy (unified)

**Scope:** how the 3.0 surface gets tested across **two repos** — the desktop app (this repo: sync foundation, E2E-crypto client, multi-writer merge, AI) and the new **`khayt-cloud`** repo (sync API, tenant isolation, multi-shop deltas). It **unifies** the per-feature Test plans already written into [Phase 0](./KHAYT-3.0-PHASE0-SPEC.md §7), [Phase 1](./KHAYT-3.0-PHASE1-SPEC.md §11), [Phase 3](./KHAYT-3.0-PHASE3-SPEC.md §9), the [Security model](./KHAYT-3.0-SECURITY-MODEL.md §7) and [AI](./KHAYT-3.0-AI-SPEC.md §7) into one strategy. It does **not** restate those DoDs; it says how they are layered, where they run, and which gate which deploy.

This **builds on** the existing harness — it does not replace it. Today: `node --test test/*.test.js` (297 tests over pure-compute + the jsdom render-path harness in `test/helpers/dom.js`), Playwright e2e (`scripts/e2e-smoke.mjs`, `scripts/e2e-theme-shells.mjs`), and `npm run lint` (a `node --check` sweep). New surface plugs into these layers, not around them.

---

## 1. Governing principle — test the invariants, not the happy path

A happy-path sync test that passes proves nothing about the properties that make Cloud safe to ship. The contract is the [security invariants](./KHAYT-3.0-SECURITY-MODEL.md §1): **cloud is optional and byte-invisible**, **the server holds ciphertext not data**, **tenant isolation is absolute**, **the AI never invents a price**. Each invariant becomes an **executable assertion that fails loudly when violated** — a golden snapshot, an adversarial cross-tenant request, a decrypt-without-key attempt, a mocked-model→deterministic-cost check. If an invariant can regress without a red test, the invariant isn't really enforced.

---

## 2. Test layers

| Layer | Runner / repo | What it covers (3.0) | Network? |
|-------|---------------|----------------------|----------|
| **Unit** | `node:test`, desktop | Stamper/fingerprint, delta extract/apply, merge policy, crypto round-trip, AI schema-validate + part-mapping. Pure functions, no DOM. | No |
| **Render-path** | `node:test` + jsdom (`helpers/dom.js`), desktop | Cloud **status/conflict UI**, AI **pre-filled quote form** (assumptions shown, owner edits) — render functions writing into real `index.html` element IDs. | No |
| **E2E** | Playwright (`scripts/e2e-*.mjs`), desktop | Full Electron boot of cloud-off + connect/sync flows, AI flow with mocked transport; extends `e2e-smoke.mjs` (store round-trip, LAN PIN gate) and `e2e-theme-shells.mjs`. | No (model + cloud stubbed) |
| **Cloud integration** | `node:test` + ephemeral PG/Redis, `khayt-cloud` | Sync push/pull, CAS/409, magic-link + refresh rotation, delta endpoints, migrations against a real schema. | Loopback only |
| **Security / adversarial** | `node:test`, `khayt-cloud` (+ desktop crypto) | Tenant-isolation fuzzing, server-can't-decrypt, portal projection allowlist, webhook signature, rate/size caps. **Mandatory gates.** | Loopback only |

Cloud integration + security run in `khayt-cloud` CI against **ephemeral Postgres + Redis** (containers spun up per job, migrations applied forward-only, torn down after) — the [infra spec](./KHAYT-3.0-CLOUD-INFRA-SPEC.md §6) pipeline: lint → unit → migration check → integration (ephemeral PG/Redis) → adversarial isolation → image → staging smoke → prod.

---

## 3. The cloud-off golden-invariant test (the keystone)

Invariant §1.1: a user who never touches cloud sees **zero** behavior change. This is enforced as **one test, not a promise**, and it is a release gate for every phase:

- `test/sync-foundation.test.js` captures a **golden snapshot** — the byte sequence `_doSave → hubAPI.saveStore` would persist for a fixed fixture store, with `KhaytSync` backend = `LocalBackend` (no-op) and cloud off.
- Every subsequent phase (P1 client, P3 delta backend, AI) re-runs the same fixture and asserts the persisted bytes are **byte-identical** to the golden, and `KhaytSync.status() === 'off'`. The stamper's reserved fields (`rev`/`updatedAt`/`_tombstones`/`_syncMeta`) are part of the golden once Phase 0 lands; nothing later may perturb them with cloud off.
- The critical companion assertion (Phase 0 §7): an **unchanged** record across two saves does **not** bump `rev` — the fingerprint excludes the reserved fields. A spurious bump would break the golden and is the most likely regression.
- E2E mirror: `e2e-smoke.mjs` boots with no cloud config and must pass unchanged — the live proof the offline app is untouched.

---

## 4. Sync / merge testing (deterministic multi-writer)

Merge is tested **deterministically** — no real clocks, no real network, fixed `rev` and op-ids — so a conflict outcome is reproducible, not flaky:

- **LWW by `rev`:** `applyDeltas` accepts higher `rev`, rejects lower (`rev` is authoritative; `updatedAt` is advisory/display, never trusted for ordering — Phase 0 §5).
- **409 / stale-push:** simulate two devices; stale push → pull → merge (rev guard) → retry once; no data loss; higher `rev` wins (Phase 1 §9, §11).
- **Multi-writer pool draw (P3):** two shops draw 100 g + 150 g from a shared spool concurrently → pool reflects **−250 g** (sum, append-union), not last-write (Phase 3 §9).
- **Idempotent delta ops:** replaying the same delta op-id is a **no-op** — applying twice equals applying once (no double-decrement). Asserted directly.
- **True tie:** equal `rev` on a shared client → surfaces a review prompt, never a silent drop; the prompt render is a render-path test.
- **Tombstones:** a delete emits a tombstone with `{id, collection}`; a later `applyDeltas` does **not** resurrect the record.

---

## 5. Crypto / E2E testing (server can't decrypt — mandatory gate)

Invariant §1.2 / §1.5 — *access ≠ decryption* — verified **by construction and by test**:

- **Round-trip (desktop unit):** plaintext store → encrypt (passphrase→KDF→data key, AEAD) → ciphertext → decrypt → **deep-equals** original (Phase 1 §11 golden compare). Wrong passphrase / tampered AEAD tag → decrypt **fails** (integrity check), never silently returns garbage.
- **Server-can't-decrypt (gate):** the cloud integration suite stores a real encrypted blob, then asserts the server, holding **only** what it received (ciphertext + metadata) and **no client key**, cannot recover plaintext — there is no code path nor stored key that decrypts. This is a **blocking** CI gate (Security §7, Phase 1 §11).
- **ODK (P3):** a newly authorized device decrypts shared data only after owner authorization; a **revoked** device cannot decrypt **post-rotation**; the server never holds a plaintext ODK (construction + test).
- **Secret redaction:** API keys / ZATCA / payment creds stay encrypted at rest and redacted from exports — reuse existing `app-security` / secret tests on both desktop and server.

---

## 6. AI testing (mocked model → deterministic calculator output)

Per AI §7, **AI tests never hit the network** — the Anthropic transport is mocked and returns a fixed structured object:

- **Extraction → calculator:** fixed request + stubbed model response → mapped `part` → `computePartBaseCost(part)` returns the **expected deterministic cost**. The determinism comes from the calculator; the model is a fixture. This is the core AI invariant test (model never invents the number).
- **Schema validation:** malformed model output is rejected/repaired and **never reaches the calculator**.
- **Material mapping:** `materialGuess` matches an inventory `filamentId`; unmatched → prompts rather than guessing.
- **No-key:** feature hidden, app behavior unchanged (render-path assert) — same cloud-off discipline.
- **Failure path:** mocked API error/timeout → falls back to the blank manual form, no crash, no partial save.

---

## 7. CI gates — which tests block which deploy

Two independent pipelines; neither blocks the other's merge, but cloud cannot deploy on a failed isolation/crypto gate.

**Desktop CI** (`.github/workflows/ci.yml`, extends today's two jobs):
- `check`: `npm run lint` + `npm test` (incl. `sync-foundation` golden + AI mocked tests). Blocks merge to `main`.
- `e2e-smoke`: `xvfb-run npm run test:e2e` (+ `test:e2e:themes`). Blocks merge.
- `release.yml` builds gated on a green golden-invariant test — no desktop release ships a cloud-off regression.

**`khayt-cloud` CI** ([infra §6](./KHAYT-3.0-CLOUD-INFRA-SPEC.md), separate repo):
- lint → unit → **migration check** → integration (ephemeral PG/Redis) → **adversarial tenant-isolation** → **server-can't-decrypt** → image → staging smoke → prod.
- **Hard deploy gates (prod blocked if red):** tenant-isolation adversarial, server-can't-decrypt, portal-projection allowlist, payment-webhook signature, rate/size caps — the [Security §7 checklist](./KHAYT-3.0-SECURITY-MODEL.md §7) as CI assertions.
- Shared API/delta/crypto contract is a versioned package; a contract bump runs contract tests in **both** repos before either deploys.

---

## 8. Coverage targets & what is intentionally not unit-tested

- **Targets:** sync engine, merge policy, crypto, and AI mapping (the invariant-bearing pure code) → **near-complete branch coverage** (every conflict/reject branch hit). Cloud query layer → 100% of paths exercise the `orgId`/`shopId` scope. These are where bugs are silent and dangerous.
- **Intentionally not unit-tested:** Electron main-process glue, native window/IPC, real canvas rendering, real Anthropic/Postgres/Redis network, and DOM **layout/pixels**. Rationale matches the existing harness: jsdom stubs canvas (`helpers/dom.js`) and does **not** execute `index.html` scripts; pixels and Electron are covered by **Playwright e2e** instead, and live infra by **staging smoke**, not unit tests. We assert behavior and structure, never visual fidelity, in unit/render-path.

---

## 9. Test-plan ownership & DoD

- Each phase **owns its own Test plan section** (already written: P0 §7, P1 §11, P3 §9, Security §7, AI §7). This strategy owns the **cross-cutting** pieces: the cloud-off golden, the shared-contract tests, and the CI gate wiring.
- **A phase is not done until** its named tests are green in the right layer **and** the cloud-off golden is still byte-identical. New invariant-bearing code lands with its test in the same PR — no "tests later."
- **Strategy-level DoD:** (1) the golden-invariant test exists and gates every desktop release; (2) tenant-isolation + server-can't-decrypt are red-or-green CI gates in `khayt-cloud`, blocking prod; (3) AI tests run with a mocked model and no network; (4) the existing 297 `node:test` + Playwright suites still pass unchanged — the 3.0 surface is **additive** to the harness, never a rewrite of it.
