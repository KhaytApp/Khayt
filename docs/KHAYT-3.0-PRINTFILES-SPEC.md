# Print-file management + gcode parsing — spec

**Scope:** attach STL/3MF/gcode files to orders, parse gcode/3MF **locally** for estimated print time + filament grams, and feed those numbers into the existing cost calculator and inventory deduction — no upload, no cloud.

**Governing principle:** the slicer already computed the truth (time + grams); we **read it, we never re-slice**. Parsing **fills the `part` fields** the calculator already consumes (`printTime`, `printWeight`); the deterministic calculator (`computePartBaseCost`) still computes the cost and `deductFilamentForOrder` still moves the stock. The parser never invents a number it can't find in the file, and the owner can override every auto-filled value before save.

---

## 1. What already exists (extend, do not rebuild)

The plumbing is mostly here — this feature finishes the wiring:
- **Parse IPC** — `main.js → ipcMain.handle('hub:parse-print-file')` (preload: `parsePrintFile`). Already reads PrusaSlicer/Slic3r, Cura `;TIME:`, Bambu `total estimated time`, and `filament used [g]` from the first 8 KB of gcode + from 3MF. Returns `{ printTimeMins, filamentGrams, filename }`.
- **Calculator hook** — `wire-events.js → #btnParseFile` already pushes the parsed values into `#printTime` / `#printWeight` / `#partFileRef` and calls `updateGrandTotal()`.
- **Per-order file vault** — `main.js → hub:copy-file-to-vault` / `list-vault-files` / `delete-vault-file` (preload `copyFileToVault`, etc.), path-confined to `userData/file-vault/<orderId>/`.
- **Attachment UI pattern** — `expenses.js → renderAttachedFiles(files)` (the `{filename, originalName, size}` row with open/remove), reused by `order-flows.js` (`draft.attachedFiles`, `pickAndSaveOrderFile`, `open-file` / `rm-file` acts).
- **Slicer profiles** — `operations-extras.js → slicerProfiles[]` ({id,name,machineId,material,layerHeight,infill,supports,notes}).

**Gaps this spec closes:** (1) the parse result is not *stored* against the part/order, so deduction can't use it; (2) the calculator button parses but doesn't bind a `filamentId` or remember the file; (3) the parser only scans the head of gcode (misses footer summaries) and lacks OrcaSlicer/Bambu-gcode + support-grams coverage; (4) no link from an attached order file → re-parse → cost refresh.

---

## 2. Data model changes (concrete fields)

**`part` (in `order.parts[]`, catalog `product.parts[]`, and the live calculator draft)** — additive, all optional:
- `printFileRef` — `{ filename, originalName, size, source }` of the gcode/3MF this part was costed from. `source` ∈ `'gcode' | '3mf' | 'manual'`. Mirrors the attachment shape so it can point at a vault file.
- `parsedTimeMins` — raw parsed estimate (minutes) before unit conversion; kept so we can show "from file" vs. an owner edit of `printTime` (hours).
- `parsedGrams` — raw parsed filament grams (model only; see support handling §4). Feeds `printWeight`.
- `parseSlicer` — detected slicer label (`'PrusaSlicer' | 'OrcaSlicer' | 'Cura' | 'BambuStudio' | null`) for display + telemetry-free debugging.
- (existing, unchanged: `printWeight`, `supportWeight`, `printTime`, `spoolCost`, `spoolWeight`, `filamentId`, `qty`, …)

**`order`** — reuse existing `attachedFiles[]` for STL/3MF/gcode (no new collection). One new flag:
- `attachedFiles[].kind` — `'print' | 'doc' | 'image'` so print files are visually grouped and offered to "re-parse into a part".

**Settings** (opt-in, off by default, same shape as other Khayt toggles):
- `settings.autoFillFromGcode` (bool, default **true** for the calculator button; the *order-file* auto-parse on attach is gated behind a confirm so it never silently overwrites edited fields).
- `settings.gcodeSupportInWeight` (bool, default true) — when the file reports model + support grams separately, route support grams to `supportWeight` instead of folding into `printWeight`.

No store-schema break: `store-validate.js` already accepts unknown keys on records; add `printFileRef`/`parsed*` to the documented part shape only.

---

## 3. Flow / UX

**A. From the calculator (primary path).** The existing `#btnParseFile` flow stays, extended:
1. Owner clicks **Parse file**, picks a `.gcode/.gco/.3mf`. Parser runs in `main.js` (local).
2. On success: fill `printTime` (hrs), `printWeight` (g), and now also stamp `printFileRef`, `parsedTimeMins`, `parsedGrams`, `parseSlicer` onto the draft part.
3. Show an inline "from <slicer> · 1h 42m · 38.4 g" chip under the part, with an **× clear** that reverts to manual. If a field was already non-empty, prompt before overwriting (honors `autoFillFromGcode`).
4. The live cost preview recomputes via `computePartBreakdown` exactly as today — no new math.

**B. From an order's attachments.** In the order editor (`order-flows.js`), the attachments list (`renderAttachedFiles`) gains a **Parse → part** action on rows where the extension is a print file. It calls `parsePrintFile` on the vaulted copy and either creates a new part or fills the selected part, then re-runs the profitability panel (`buildProfitabilityHtml`).

**C. Material binding.** Parsing fills time/grams but **not** `filamentId`. Keep the existing inventory picker; if the part has no `filamentId` and exactly one spool of the order's material matches, suggest it (do not auto-bind silently). This keeps deduction correct.

---

## 4. gcode / 3MF parsing detail

All parsing is in `hub:parse-print-file` (extend it). Read **head (first ~16 KB) and tail (last ~16 KB)** of gcode — Cura/Orca write the summary near the top, PrusaSlicer/Bambu in the footer. Comment keys to read (case-insensitive), first match wins per metric:

**Print time (→ minutes):**
- PrusaSlicer / OrcaSlicer: `; estimated printing time (normal mode) = 1h 42m 8s` (also `… (silent mode) …` — prefer *normal*). Parse `Nd Nh Nm Ns`.
- Cura: `;TIME:<seconds>` → `/60`.
- Bambu Studio (gcode): `; total estimated time: 1h 42m` and/or `; model printing time: …` — prefer total.

**Filament used (→ grams):**
- PrusaSlicer / Orca: `; filament used [g] = 38.42` (model). Support grams, when present: `; filament used [g] (support) = 4.1` → `supportWeight` if `gcodeSupportInWeight`, else add to total.
- Cura: `;Filament weight = 38.4` or the `FILAMENT_WEIGHT` token (already handled) — keep both.
- Bambu: `; filament used [g] = …` (same as Prusa key) or `; total filament weight [g] : …`.
- **Multi-extruder / AMS:** files may list `filament used [g] = 12,8,4`. Sum the comma list for total grams.

**3MF:** unzip-free latin1 scan (already done) of `Metadata/Slic3r_PE.config` / `*.gcode` embedded text for the same `estimated printing time` + `filament used [g]` keys. Bambu `.3mf` stores plate JSON — best-effort regex for `"weight"` / `"prediction"`; if absent, fall through.

**Fallbacks when a key is absent:**
- Time missing, grams present → fill grams only, leave `printTime` for manual entry; toast `calc.parse_partial`.
- Both missing (e.g. raw STL, unknown slicer) → no fields touched; toast `calc.parse_failed`; STL still attaches as a file.
- Never throw to the renderer — return `{printTimeMins:null, filamentGrams:null, …}` on any read error (current behavior).

---

## 5. Integration points (exact files / functions)

- `main.js` → `ipcMain.handle('hub:parse-print-file')` — extend regex set (Orca/Bambu, support grams, multi-extruder), add tail-read, return `slicer` + `supportGrams`.
- `preload.js` → `parsePrintFile` — return shape gains `slicer`, `supportGrams` (no signature change).
- `renderer/wire-events.js` → `#btnParseFile` handler — stamp `printFileRef`/`parsed*` on the draft part, route `supportGrams` per `gcodeSupportInWeight`, render the "from file" chip.
- `lib/calculator-cost.js` → `computePartBaseCost` / `computePartBreakdown` — **unchanged**; they already read `printWeight`, `supportWeight`, `printTime`. This is the contract we fill.
- `renderer/order-flows.js` → order editor attachment list — add `data-act="parse-to-part"`; on order create, carry `printFileRef`/`parsed*` through `parts.map(...)` (line ~93).
- `renderer/inventory.js` → `deductFilamentForOrder` / `partGramsConsumed` — **unchanged**: they already deduct `printWeight (+ support) × qty` per `part.filamentId`. Parsed grams feed `printWeight`, so deduction "just works" once the part is bound to a spool.
- `renderer/expenses.js` → `renderAttachedFiles` — reused as-is; print files get the `kind` badge.
- `renderer/operations-extras.js` → `slicerProfiles` — optional: when a profile matches the detected `material`/`machineId`, offer to apply its `material` to the part's spool suggestion.
- Locale keys: `calc.parsed_toast`, `calc.parse_partial`, `calc.parse_failed` exist; add `calc.from_file_chip`, `calc.clear_parsed`, `oe.parse_to_part`, `set.autofill_gcode`, `set.gcode_support_weight` to `en.js` + `ar.js` (+ other locales).

---

## 6. Edge cases

- **Owner edited then re-parses** → confirm before overwrite; clearing the chip reverts `printTime`/`printWeight` to blank, not to the old parsed value.
- **qty > 1** — parsed grams are **per print job as sliced**. Document that `printWeight` is per-unit; if the gcode is a multi-up plate, the owner must divide. Do not guess plate count.
- **Resin (.gcode from resin slicers)** — `computePartBaseCost` treats resin as `spoolCost/1000 × grams`; parsed grams still apply, but most resin slicers report mL, not g. If only mL is found, leave weight manual (resin density varies).
- **Huge files** — gcode head/tail read avoids loading multi-GB files; 3MF keeps the existing 50 MB guard.
- **Path safety** — only parse files inside the already-allowlisted dirs (userData/documents/downloads/desktop/temp) — current guard stays.
- **Comma-locale numbers** — `38,4` vs `38.4`; normalize decimal comma only when it's clearly a decimal (single trailing group), not a multi-extruder list.
- **No `hubAPI`** (pure web/LAN build) — buttons hidden when `window.hubAPI?.parsePrintFile` is absent (current guard).

---

## 7. Test plan & Definition of Done

- **Parser unit tests** (no Electron): feed fixture gcode headers/footers from PrusaSlicer, OrcaSlicer, Cura, Bambu → assert `{printTimeMins, filamentGrams, supportGrams, slicer}`. Include a multi-extruder comma list and a support-grams line.
- **Fallback:** STL / unknown slicer → all-null result, no throw; partial (grams only) path asserted.
- **Calculator contract:** a parsed result → stamped `part` → `computePartBaseCost(part)` returns the same cost as the equivalent hand-entered part (parsing changes inputs, not math).
- **Deduction:** order with a parsed, spool-bound part → `deductFilamentForOrder` removes `printWeight (+support) × qty` from the chosen spool (reuse existing deduction tests).
- **Overwrite guard:** re-parse over edited fields prompts; clear reverts to blank.
- **Opt-in:** `autoFillFromGcode` off → calculator button still parses on click but never auto-applies; `gcodeSupportInWeight` toggles support routing.
- **No-Electron / no-key:** feature degrades to plain file attach; app unaffected.

**DoD:** attaching or picking a gcode/3MF locally fills print time + grams into the calculator, stamps a re-parseable `printFileRef`, prices via the unchanged calculator, and (when the part is spool-bound) deducts the parsed grams through `deductFilamentForOrder` — all offline, all overridable, with zero change to behavior when no print file is provided.
