# Khayt-4 design implementation plan

Design reference: `design/khayt-4/design_handoff_khayt/` (see README there).

This document maps the **eight handoff directions** to the production theme system and breaks implementation into shippable phases.

## Direction → registry mapping

| Handoff | Name | Folder | Production ID (proposed) | Shell type | Status in app |
|---------|------|--------|--------------------------|------------|---------------|
| A | Production Studio | `khayt/` | `studio` | `studio` (sidebar) | **~75%** — shell, tokens, 5/6 screens |
| B | Workshop Ledger | `alt/` | `ledger` | `ledger` (masthead + tabs) | **~40%** — shell strong, screens weak |
| C | Control Room | `console/` | `console` | `console` (command bar + code rail) | **Shipped** — tokens, shell, screens, picker |
| D | Atelier | `atelier/` | `atelier` | `atelier` (soft sidebar) | **Shipped** |
| E | Vitrine | `vitrine/` | `vitrine` | `vitrine` (glass sidebar) | **Shipped** |
| F | Cockpit | `cockpit/` | `cockpit` | `cockpit` (icon rail + ops layout) | **Shipped** |
| G | Spectrum | `spectrum/` | skins via `cockpitSkin` | `cockpit` + `data-skin` | **Shipped** (lumen/draft/clay) |
| H | Frontier · Atlas | `frontier/` | `atlas` | `atlas` (spatial floor map) | **Shipped** |
| H | Frontier · Pulse | `frontier/` | `pulse` | command palette | Reserved (coming soon) |
| H | Frontier · Stream | `frontier/` | `stream` | conversational feed | Reserved (coming soon) |

**Legacy reserved IDs** (`blueprint`, `atlas` in `registry-core.js`) should be renamed or aliased:

- `blueprint` → likely **Spectrum Draft** skin or **Control Room** (pick one; avoid two “blueprint” meanings)
- `atlas` → **Frontier · Atlas** concept (spatial floor map) — keep reserved until paradigm is chosen

## Architecture decisions

### Two shell families

1. **Classic multi-screen** (A–E): same six screens (`khayt/*.jsx`), different DS + shell per folder.
2. **Cockpit family** (F–G): `ck-*` classes, icon rail, Overview = fleet + Gantt + attention; other sections in `cockpit/sections.jsx`.

Production needs new shell types in `registry-core.js`:

```
studio | ledger | console | atelier | vitrine | cockpit
```

Each shell = tokens + shell CSS/JS under `renderer/themes/<id>/`.

### Screen enhancement layer

Today, polished render paths live in `renderer/studio/studio.js` and are **Studio-gated** (`isStudio()`).

**Required refactor:** theme-agnostic screen APIs used by all A–E themes (and Cockpit sections where applicable):

- `renderer/themes/screens/` or extend `KhaytStudio` → `KhaytScreens` with `getActiveDesign()` checks
- Dashboard KPI grid, queue filters/folds, calculator breakdown, inventory stats, client cards, analytics layout

### Fonts per direction

Vendor only fonts for shipped themes. Khayt-4 adds:

| Direction | UI | Mono | Display |
|-----------|-----|------|---------|
| A Studio | Hanken Grotesk | Geist Mono | — |
| B Ledger | Archivo | IBM Plex Mono | — |
| C Console | IBM Plex Sans | JetBrains Mono | — |
| D Atelier | Albert Sans | Spline Sans Mono | Newsreader |
| E Vitrine | Outfit | Geist Mono | — |
| F/G Cockpit | Bricolage Grotesque / Plus Jakarta / Space Grotesk / Quicksand | IBM Plex Mono / DM Mono | — |

Run `node scripts/vendor-theme-fonts.mjs` after adding `@fontsource/*` deps.

### Do not port

- `tweaks-panel.jsx`, `design-canvas.jsx`
- React/Babel prototype runtime
- `window.KHAYT` mock data (use real app data)

## Phased rollout

### Phase 0 — Handoff ingest (this PR)

- [x] Commit `design/khayt-4/design_handoff_khayt/`
- [ ] This implementation plan
- [ ] Align `docs/THEMES.md` with Khayt-4 naming

### Phase 1 — Finish A + B (ship what users can pick today) — **complete**

1. ~~Theme-agnostic screen layer (`body.khayt-handoff`, `KhaytStudio.useHandoffScreens()`)~~
2. ~~Ledger gets KPI/queue/calc/inventory/clients polish~~
3. ~~Handoff analytics overview (KPI row, machine P&L, heatmap, top clients)~~
4. ~~Scope `renderer/studio/ds.css` to `html[data-design="studio"]`; shared primitives in `handoff-screens.css`~~
5. ~~App-only tabs + Settings: handoff CSS, SVG settings nav icons, Ledger page subtitles~~
6. ~~Theme preview PNGs for studio + ledger~~

**Exit:** Switching Studio ↔ Ledger feels like two complete apps on all six handoff screens.

### Phase 2 — Registry expansion + one new theme — **Control Room complete**

Shipped **Control Room** (`console`) as third selectable built-in:

1. ~~Port `console/ds.css` → `renderer/themes/console/tokens.css`~~
2. ~~Port shell → `renderer/themes/console/shell.css` + `shell.js` (`KhaytConsoleShell`)~~
3. ~~Register in `registry-core.js`, locale keys, IBM Plex Sans + JetBrains Mono fonts~~
4. ~~Handoff screens via `body.khayt-handoff` + `screens.css`~~
5. Preview: `themes/previews/console.png` via `npm run capture:theme-previews`

### Phase 3 — Remaining A–E themes — **complete**

Shipped **Atelier** and **Vitrine** as fourth and fifth selectable built-ins:

1. ~~`renderer/themes/atelier/` — tokens, compat, floating sidebar shell, screens~~
2. ~~`renderer/themes/vitrine/` — tokens, compat, ambient glass shell, screens~~
3. ~~Registry enabled; Albert Sans, Newsreader, Spline Sans Mono, Outfit fonts vendored~~
4. ~~Previews: `atelier.png`, `vitrine.png` via `npm run capture:theme-previews`~~

**v1 A–E picker is complete.**

### Phase 4 — Cockpit + Spectrum — **complete**

Shipped **Cockpit** as sixth selectable built-in with **Spectrum** skins:

1. ~~`renderer/themes/cockpit/` — tokens, spectrum skins, shell CSS, sections scaffold, compat~~
2. ~~`KhaytCockpitShell` — 74px icon rail, filtered nav, stats bar, skin sync~~
3. ~~`KhaytCockpitOverview` — fleet list + day timeline + attention feed (real app data)~~
4. ~~Settings `cockpitSkin`: `poster` | `lumen` | `draft` | `clay` via `data-skin` on `<html>`~~
5. ~~Bricolage Grotesque + Plus Jakarta Sans fonts; preview `cockpit.png`~~

### Phase 5 — Frontier · Atlas — **complete**

Shipped **Atlas** as seventh selectable built-in; Pulse and Stream reserved:

1. ~~`renderer/themes/atlas/` — tokens, shell CSS, compat, spatial floor renderer~~
2. ~~`KhaytAtlasShell` — chromeless layout, shared topbar, Floor/Queue/Settings nav~~
3. ~~`KhaytAtlasFloor` — zone map, machine stations, inspector from real fleet data~~
4. ~~Space Grotesk font; preview `atlas.png`; Pulse + Stream in coming-soon registry~~

**Pulse** and **Stream** remain reserved Frontier concepts for a future vNext pass.

### Phase 6 — QA — **complete**

1. ~~`test/themes-qa.test.js` — preview PNGs, en locale keys, shell body classes~~
2. ~~`scripts/e2e-theme-shells.mjs` — dashboard + queue + settings per all 7 themes~~
3. ~~RTL smoke: Atlas + Arabic (`document.documentElement.dir === 'rtl'`)~~
4. ~~Arabic locale: theme design + cockpit skin keys in `ar.js`~~
5. ~~Theme previews: `npm run capture:theme-previews` (7 PNGs)~~

## File reference (handoff → app)

| Handoff | App target |
|---------|------------|
| `khayt/ds.css` | `renderer/studio/ds.css` (A) |
| `alt/ds.css` | `renderer/themes/ledger/tokens.css` (B) |
| `console/ds.css` | `renderer/themes/console/tokens.css` |
| `atelier/ds.css` | `renderer/themes/atelier/tokens.css` |
| `vitrine/ds.css` | `renderer/themes/vitrine/tokens.css` |
| `cockpit/cockpit.css` | `renderer/themes/cockpit/cockpit.css` |
| `spectrum/themes.css` | `renderer/themes/spectrum/themes.css` |
| `khayt/*.jsx` screens | `renderer/dashboard.js`, `kanban.js`, `build.js`, etc. |
| `khayt/icons.jsx` | `renderer/studio/icons.js` (+ per-theme hydration) |
| `khayt/charts.jsx` | `renderer/studio/charts.js` |

## Recommended pick order (product)

If shipping incrementally for users:

1. **Finish A + B** — already in Settings; highest ROI
2. **C Control Room** or **D Atelier** — distinct third option
3. **F Cockpit** — flagship “ops” experience (new default candidate?)
4. **G Spectrum** — three skins without three shells
5. **E Vitrine** — glass aesthetic (more CSS complexity)
6. **H Frontier** — after paradigm choice

## Open questions

1. Which directions should appear in **Settings → Design** for v1? (All 6 production-realistic? Cockpit only? Spectrum skins as separate entries?)
2. Is **Cockpit** intended to **replace** classic multi-screen nav long-term?
3. Should **Frontier · Atlas** keep the reserved `atlas` registry ID?
4. Merge order: land Phase 1 on `main` via PR #74 before new theme PRs?
