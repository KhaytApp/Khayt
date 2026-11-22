# Onboarding & data import — implementation spec

**Scope:** get a new Saudi shop productive on day one. Two halves: (1) a **guided first-run wizard** that captures business info, currency/VAT/ZATCA, a first printer (machine), and a first material (spool) by reusing existing settings fields; (2) **data import** — bring existing clients, inventory, and orders in from CSV, a competitor export, or a spreadsheet. Composes with [KHAYT-3.0-MIGRATION-SPEC.md](./KHAYT-3.0-MIGRATION-SPEC.md) (every imported record flows through the migration pipeline) and [KHAYT-3.0-PRIVACY-COMPLIANCE-SPEC.md](./KHAYT-3.0-PRIVACY-COMPLIANCE-SPEC.md) (imported rows carry customer PII). Optional AI tie-in for fuzzy column mapping borrows the BYO-key model from [KHAYT-3.0-AI-SPEC.md](./KHAYT-3.0-AI-SPEC.md).

**Governing principle:** **reuse, don't reinvent.** We already have `parseCsvString` (`renderer/util.js`), `openCsvImportModal` with auto-column-mapping (`renderer/app-helpers.js`), three working importers (`importClientsCsv` / `importSpoolsCsv` / `importProductsCsv` in `renderer/inventory.js`), full backup restore via `replaceStoreFromSnapshot`, and a setup wizard (`renderer/app-boot.js`). Onboarding is **wiring and polish over these primitives**, plus one new collection (orders). Three hard rules: (a) every imported record gets a `uid()` id and must pass the relevant `store-validate.js` filter; (b) imports **never silently overwrite** existing data — they merge-by-dedup or create new, and a full-replace path requires explicit confirm + a pre-import backup; (c) everything is local-first — no network call except the optional BYO-key AI mapping step.

---

## 1. Guided onboarding (first-run wizard)

Extend the **existing** wizard (`initWizard` / `shouldShowSetupWizard` in `renderer/app-boot.js`), gated by `settings.firstRun` / `settings.firstRunDone`. `normalizeWizardFlagsAfterLoad` already auto-completes the wizard for shops that arrive with data (upgrade/import), so the wizard only shows for genuinely empty installs. Steps (each writes the **same `settings` keys** `defaultSettings()` already defines — no new schema):

1. **Language & business info** — `lang`, `bizEn`, `bizAr` (Arabic name required for ZATCA), `phone`, `email`, `addrEn`/`addrAr` (default `الرياض، المملكة العربية السعودية`), `cr`, `vat`. Reuse `loadSettingsIntoForm` field bindings.
2. **Currency / VAT / ZATCA** — `currency` (default `SAR`), `enableVat` + `vatRate` (default 15), `enableZatca` (Phase-2 left off; `zatcaPhase2.enabled=false`). Mirrors the existing `#wizEnableZatca` checkbox.
3. **First printer** — push one `machines[]` record (`{ id: uid('MCH'), name, … }`); optional, skippable.
4. **First material** — push one `inventory[]` spool via the same shape `importSpoolsCsv`/`addInventoryItem` use (`{ id: uid('S'|'INV'), material, cost, weight, … }`); offer the seed defaults (PLA+, PETG, TPU) as one-click presets.
5. **Import existing data (optional)** — a CTA that opens the import hub (§2). Skipping leaves an empty, ready shop.

On finish the wizard already sets `firstRun=false; firstRunDone=true; await flushSave()` then `initialRender()` — unchanged. Add an **"already using another tool?"** branch on step 1 that jumps straight to import.

---

## 2. Data import (CSV → clients / inventory / orders)

Reuse `openCsvImportModal({ title, fields, onImport })`. It already: reads a file (`FileReader`, UTF-8) or pasted text, calls `parseCsvString`, **auto-maps** columns by normalized header match (`autoMapIdx`), renders a mapping table with a live preview + valid-row count, enforces `required` fields, and coerces `type:'number'`. We keep this verbatim and only add a **dry-run preview** and **dedup reporting** to the `onImport` callbacks.

- **Clients** — `importClientsCsv` exists. Fields: `nameEn`(req)/`nameAr`/`phone`/`email`/`city`/`address`/`vat`/`company`/`notes`. Each row → `{ id: uid('CL'), …, createdAt: localDateStr(), commLog: [] }`, then `saveAll()` + `renderClients()`. Add `source:'import'` so imported clients are badged (the clients table already renders `source` badges).
- **Inventory** — `importSpoolsCsv` exists; maps to the spool shape (`material`, `weight`, `weightTotal`, `cost`, `reorderPoint`, `location`). Each row → `{ id: uid('S'), …, addedAt: localDateStr() }`.
- **Orders** — **new** `importOrdersCsv`. Fields: `date`(req)/`project`(req)/`status`/`clientName`/`price`/`material`/`notes`/`paymentStatus`/`dueDate`. Each row → a record matching `logPrint`'s shape (`renderer/order-flows.js`): `{ id: uid('ORD') or sequenced INV-YYYY-NNNN, date, project, status:(validated against the kanban set, default 'completed' for historical rows), price:+n, statusHistory:[…], parts:[], trackingToken, materialDeducted:false, … }`. **Link by name:** match `clientName` to an existing client (case-insensitive `nameEn`/`nameAr`), else create a stub client. Imported historical orders default to `status:'completed'` + `paymentStatus:'paid'` so they don't pollute the active kanban.

**Validation contract:** before committing, run candidates through the matching `store-validate.js` predicate — `isValidClient`, `isValidInventoryItem`, `isValidOrder` (which requires non-empty `id`/`date`/`status`/`project` strings). Rows that fail are counted as skipped, never pushed. After commit, the next `loadAll` carries them through `normalizeStoreSnapshot` + `KhaytMigrate.run` like any other record — no special-casing.

---

## 3. Competitor / spreadsheet import

Two layers on top of §2's generic modal:

- **Templates** — ship downloadable CSV templates (clients/inventory/orders) with header rows that exactly match each importer's `key`/`label` so `autoMapIdx` maps them with zero clicks. A "Download template" link sits beside "Choose CSV file".
- **Known-exporter presets** — a small dropdown of header-alias maps for common Saudi/3D-print tools and generic spreadsheet headers (e.g. `الاسم`→`nameEn`/`nameAr`, `الجوال`→`phone`, `السعر`→`price`). Selecting a preset pre-fills the mapping selects; the user still confirms.
- **AI-assisted mapping (optional, BYO key)** — when an Anthropic key is configured (same BYO-key contract as [KHAYT-3.0-AI-SPEC.md](./KHAYT-3.0-AI-SPEC.md): no Khayt Cloud, owner-supplied key), a "Suggest mapping" button sends **only the header row + 1–2 sample rows** (never the full file, minimizing PII egress) and asks the model to propose `header → field` mappings. The model **only sets the dropdowns** — it never writes to the store, never invents values. Owner reviews every mapping before import. Absent a key, the button is hidden; everything else works offline.

---

## 4. Import safety

- **Dry-run preview** — the existing modal already shows "N rows will be imported." Extend the `onSave` path to first compute, without mutating state, an `{ imported, skipped, duplicates, invalid }` summary and show it for confirmation before pushing.
- **Dedup vs existing (never silent overwrite)** — the existing importers already skip rows that collide with current data (clients by `nameEn`/`phone`/`email`; spools by `material`+`brand`+`color`; products by `nameEn`/`sku`). Keep this **merge-or-new** default. For collisions, offer per-batch choice: **Skip** (default), **Add as new** (fresh `uid`), or **Update** (merge non-empty fields into the existing record). There is no row-level silent overwrite.
- **Full-replace path** — only via the existing backup restore (`replaceStoreFromSnapshot`, `renderer/settings.js`), which already shows a `danger` confirm. Before any replace **or** large merge, auto-write a backup (`window.hubAPI.writeBackup`, reusing `maybeAutoBackup`'s payload from `buildExportPayload`) so the user can roll back via the existing restore-backup picker.
- **Rollback** — the pre-import backup + restore UI is the rollback. Additionally, since import appends, an "Undo import" toast action (like `deleteClient`'s undo) can remove the just-added ids by tracking them in a session array.

---

## 5. Integration points (exact files/functions)

| Concern | Reuse / add |
| --- | --- |
| CSV parse | `parseCsvString` — `renderer/util.js` |
| Import modal + auto-map | `openCsvImportModal`, `autoMapIdx` — `renderer/app-helpers.js` |
| Client import | `importClientsCsv` — `renderer/inventory.js` (+ `source:'import'`) |
| Inventory import | `importSpoolsCsv` — `renderer/inventory.js` |
| Order import | **new** `importOrdersCsv` — match `logPrint` shape in `renderer/order-flows.js` |
| Ids | `uid(prefix)` — `renderer/util.js` |
| Validation | `isValidClient` / `isValidInventoryItem` / `isValidOrder` — `lib/store-validate.js` |
| Migration pass | `normalizeStoreSnapshot` + `KhaytMigrate.run` via `loadAll`/`applyStoreFromSnapshot` — `renderer/app-state.js` |
| Full replace / restore | `replaceStoreFromSnapshot`, restore-backup UI — `renderer/app-state.js`, `renderer/settings.js` |
| Pre-import backup | `buildExportPayload` + `window.hubAPI.writeBackup` — `renderer/store.js`, `renderer/app-exports.js` |
| Wizard | `initWizard`, `shouldShowSetupWizard`, `normalizeWizardFlagsAfterLoad` — `renderer/app-boot.js` |
| Settings fields | `defaultSettings`, `loadSettingsIntoForm` — `renderer/app-state.js`, `renderer/settings.js` |

---

## 6. Edge cases

- **Bad rows** — missing required field, unparseable number, invalid `status`/`date`: counted as `invalid`/skipped, surfaced in the preview, never pushed (already enforced by the modal's `required`/`type` logic + `store-validate` predicates).
- **Duplicates** — handled by §4 dedup; report counts so the user sees what was merged vs added vs skipped.
- **Encoding / Arabic** — `FileReader.readAsText(file, 'UTF-8')` is already used; exports are written BOM-prefixed (`'﻿'`). Document that Excel-on-Windows CSVs may be CP-1256; offer a paste fallback. RTL names (`nameAr`, `addrAr`) flow through untouched — no transliteration.
- **Partial import** — commit is all-valid-rows-or-nothing per click is **not** required; we commit the valid subset and report the skipped remainder so a few bad rows don't block a 500-row file. Each commit is atomic at `saveAll()`.
- **Huge files** — `parseCsvString` is synchronous and in-memory. Guard with a row-count cap (warn > ~5,000 rows) and chunk the `onImport` push + a single debounced `saveAll()`. AI mapping only ever sees the header + samples, so file size never reaches the model.
- **Empty / header-only file** — `parseCsvString` returns `{ headers, rows:[] }`; modal shows "No data to import" and disables import.
- **Re-running the wizard** — `settings.firstRun=true; firstRunDone=false` reset path (already in `settings.js`) must not wipe imported data; the wizard's step 4/5 only push when the user opts in.

---

## 7. Test plan & DoD

**Unit (pure, no DOM):**
- `importOrdersCsv` row → record passes `isValidOrder`; missing `project`/`date` rejected.
- Client name→client linking: exact `nameEn`, exact `nameAr`, no-match-creates-stub.
- Dedup predicates: duplicate by phone, by email, by name; spool dup by material+brand+color.
- Number coercion (`price`, `weight`, `cost`) and Arabic-numeral / RTL passthrough.
- Round-trip: `exportClientsCsv` output re-imported via `importClientsCsv` yields equivalent records (import is the inverse of export).

**Integration:**
- Import → `saveAll` → reload → records survive `normalizeStoreSnapshot` + `KhaytMigrate.run` with correct version stamp.
- Pre-import backup written; restore via `replaceStoreFromSnapshot` rolls back exactly.
- Wizard finish on empty install creates expected `settings`/`machines`/`inventory`; wizard skipped for installs that already have data (`normalizeWizardFlagsAfterLoad`).
- Encoding: UTF-8 Arabic CSV imports without mojibake.

**DoD:**
- All three CSV types import with auto-mapping; orders link to clients.
- No code path overwrites an existing record without explicit user confirm; every import auto-backs-up before a replace/large merge.
- Every imported record has a `uid` id, passes its `store-validate` filter, and survives a reload through the migration pipeline.
- Wizard reuses existing settings fields (zero new settings keys); BYO-key AI mapping is optional and degrades to manual mapping offline.
- Strings localized EN/AR; SAR + 15% VAT defaults; Arabic names/addresses preserved.
