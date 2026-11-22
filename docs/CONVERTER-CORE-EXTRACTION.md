# The converter engine exists twice — a plan to make it exist once

> **Status: proposal, nothing has moved.** Written 2026-08-05 after measuring the
> duplication rather than assuming it. Read §1 before agreeing to §3 — the evidence is
> what makes the staging defensible, and it also says which parts should *not* be merged.
>
> **Re-verified 2026-08-12**, 43 commits later, before merging a week-old analysis.
> Every line count in §1 is unchanged — `color-mix.js` 136, `color-bands.js` 175,
> `full-spectrum.js` 337, `mf-convert.js` 1249 — so the duplication and the staging
> still stand. One figure moved: Bed Ready now loads **129** scripts, not 126, because
> `lib/invoice-language.js` and `lib/tax.js` were added in the meantime. Both are
> shared, so the shared proportion went slightly UP and the conclusion in §0 — that a
> repo split would mean hand-reconciling something every commit touches — holds harder
> than when it was written.

## 0. What this is not

This is **not** the Khayt/Bed Ready repo split. That was the question that started this,
and the measurements answered it the other way:

| measure | value |
|---|---|
| scripts Bed Ready loads | 126 |
| …shared with Khayt | **107 (85%)** |
| Bed-Ready-only | 19 |
| of the last 60 commits on `main`, how many touched shared core/lib | **60 / 60** |

Every commit touches shared code, and 85% of Bed Ready *is* shared code. Splitting those
two apps into separate repos with a "middle repo we both check for updates" means manually
reconciling something that moves on every single commit — which is the duplicated work the
one-repo/one-core arrangement was chosen to avoid in the first place
([docs/BEDREADY-APP.md](./BEDREADY-APP.md)). Khayt↔Bed Ready is already solved: one build,
one core, a converter fix lands in both automatically.

**The sync pain is elsewhere: the Bed Ready *app* and the bedready.io *website*.**

## 1. The actual duplication, measured

The same engine is implemented twice — once in JS in this repo, once in TS in
`~/dev/3DWebsite` — and kept in step by hand. The porting has gone both directions
(website→app in #367; app→web in the site's #31), which is how you can tell nobody owns it.

| concept | app (this repo) | website | lines | verdict |
|---|---|---|---|---|
| colour maths | `lib/color-mix.js` | `src/lib/color-mix.ts` | 136 / 142 | **identical twins** |
| colour bands | `lib/color-bands.js` | `src/lib/color-bands.ts` | 175 / 155 | **identical twins** |
| full spectrum | `lib/full-spectrum.js` | `src/lib/mixed-filament.ts` | 337 / 97 | **app is 3.5× richer** |
| converter core | `lib/mf-convert.js` | `src/lib/convert.ts` | 1249 / 2242 | two different programs |
| mesh / paint | `lib/mf-mesh.js` | `src/lib/paint.ts` | — | port, drifting |
| worker | `lib/mf-worker.js` | `src/lib/clean.worker.ts` | — | different runtimes |
| orca filaments | `lib/orca-filament-install.js` | `src/lib/orca-filaments.ts` | — | different jobs |

**This is a spectrum, not a uniform copy-paste.** That is the single most important fact in
this document, because it means "merge the engine" is the wrong instruction — some of these
should be merged, one should probably never be.

> **Correction (2026-08-06).** The first draft of this table called `color-bands` *drifted*,
> on the strength of the 175-vs-155 line difference and a function-name grep. That was wrong.
> Running both over 45 scenarios found **zero disagreements** — the extra lines are TypeScript
> types and one extra export. Line counts are not evidence of behaviour, and the two rows still
> marked as differing (`full spectrum`, `converter core`) are differing *by size and shape*;
> only the two now marked "identical twins" have actually been run against each other. The
> harness in phase 0 exists precisely so this stops being guesswork.

### 1.1 The colour layer and band detection are provably identical

Both expose the same nine colour functions — `blend, ciede2000, deltaE, gradient, hexToLab,
hexToRgb, nearest, rgbToHex, rgbToLab` — and both expose `detectColorBands` with an identical
signature. Differential runs over the same inputs found **zero disagreements**:

```
610 calls compared across blend / deltaE / nearest      — mismatches: 0
 45 scenarios compared across detectColorBands          — mismatches: 0
```

So for this layer, extraction is a *consolidation of two things that already agree*, not a
reconciliation of two behaviours. It cannot silently change output, because there is no
disagreement to resolve. That is why it goes first.

### 1.2 The app already loads like a package

`lib/color-mix.js` ends:

```js
if (typeof module !== 'undefined' && module.exports) module.exports = api;
global.KhaytColor = Object.assign(global.KhaytColor || {}, api);
```

Dual CommonJS + browser-global, no bundler required. **The consumption pattern a shared
package would need on the app side already exists and is already in use.** The app can keep
loading `<script>` tags exactly as it does now; the package just has to emit that shape.

## 2. Why this is worth doing at all

Not for elegance. Three concrete costs today:

1. **Every converter improvement is written twice**, in two languages, by hand.
2. **They could drift silently, and nothing would say so.** As of phase 0 the layers that
   have actually been compared all agree — so this is a risk being closed before it bites,
   not damage being repaired. What made it worth doing first is that a divergence here is
   invisible: no error, no warning, just the same user getting different colours from the
   website and the app.
3. **A fix can land in one product and be forgotten in the other for months.** The site is
   the front door (`/convert` is the homepage CTA); the app is the paid-attention product.
   Divergence between them is visible to the same user.

## 3. The plan, staged by risk

Each phase is independently valuable and independently abandonable. **Do not start phase N+1
until phase N has been live for a while.**

### Phase 0 — a differential harness (do this even if you do nothing else) ★ **DONE**

**Shipped** as `src/lib/engine-parity.test.mts` in the website repo (Alballaa/bedready#74).
It runs **both** implementations over the same inputs and fails when they disagree — 610
colour comparisons and 45 band-detection scenarios — and CI checks out `KhaytApp/Khayt` so
it genuinely runs rather than skipping. Without the app source present it skips with a
visible reason instead of failing, so a website-only contributor is not punished for a repo
they do not have.

This is the highest-value item in the document and the cheapest:

- It is the **safety net** for every later phase — "behaviour unchanged" stops being a claim
  and becomes a test result.
- On its own, without moving a single file, it **converts silent drift into a red build.**
  Today it locks in agreement rather than reporting a break — which is the good case, and the
  reason to do it now rather than after something has already gone wrong.
- If phases 1–3 are never done, this still fixes the worst property of the current setup.

Where it lives is a real question, since it needs both repos checked out. Simplest workable
answer: in the website repo (it already has `tsx` + a test runner), reading the app's `lib/`
from a path or a git submodule pinned to `main`.

### Phase 1 — extract the colour layer

Move the nine colour functions into one package. Author in TS, emit two artifacts:

- **ESM** for the website (`import { deltaE } from "@bedready/core"`)
- **IIFE/global** for the app, preserving `globalThis.KhaytColor` — so `bedready.html` and
  `index.html` keep their `<script>` tags and gain no bundler

Risk is genuinely low: §1.1 proves the two behave identically today, and the phase-0 harness
proves it still does afterwards. If this phase is painful, that is the signal to stop — and
you will have learned it for the price of one small module.

### Phase 2 — reconcile the drifted siblings

`mesh/paint`, and anything else phase 0 is extended to cover. These need a **decision**, not
a move: where two versions genuinely differ, someone has to say which behaviour is correct.
The phase-0 harness is what makes that decision informed — it shows exactly which inputs
produce different answers.

`color-bands` was listed here in the first draft and has been removed: it does not differ.
Extend the harness to `mesh/paint` before assuming that one does either.

Expect this to surface at least one real bug in one of the two products.

### Phase 3 — the hard ones, and maybe never

`full-spectrum.js` (337 lines) vs `mixed-filament.ts` (97), and `mf-convert.js` (1249) vs
`convert.ts` (2242). These are not ports of each other; they are two programs that share a
purpose. The app's Full Spectrum is substantially richer; the website's converter handles
target/UI concerns the app does not have.

**The honest recommendation is to share their *primitives* and leave the orchestration
separate.** Forcing a single `convert()` across an Electron main process and a browser
worker is how this project would acquire the bundler it has done well to avoid. Revisit only
if phases 1–2 make it look easy.

## 4. Where the shared package should live

A dedicated repo — this is the "middle repo" instinct, with the right two parties. Consumed
as a real versioned dependency, **not** a place to browse for changes to copy: at 60-of-60
commits touching shared code, "check it for updates" degrades into manual porting within
weeks, which is the disease rather than the cure.

Start by consuming it from a git URL/tag rather than publishing to npm — same versioning
guarantee, none of the registry ceremony, and reversible.

## 5. How we prove nothing broke

1. The phase-0 differential harness stays green (this is the real proof).
2. Both existing suites stay green — this repo's 2054 unit tests + CI e2e; the site's 217
   tests, `tsc`, and its 3,744-page build.
3. A real `.3mf` converts to a byte-identical result before and after, in **both** products.
4. `npm run check:globals` still passes — it is what catches a renderer global that stopped
   being loaded, which is exactly the failure mode a packaging change can introduce.

## 6. What would make me say don't

- If phase 0 shows the colour layer *disagreeing* in real use, the priority changes from
  packaging to fixing a live bug — do that first, separately.
- If the app ever needs a bundler to consume the package, stop. The no-bundler `<script>`
  architecture is load-bearing for this codebase and is not worth trading for tidiness.
