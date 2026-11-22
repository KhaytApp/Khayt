# Khayt — UI Redesign Handoff (two directions)

This folder contains **two complete, alternative UI directions** for the Khayt
desktop app, plus drop-in token files and an adaptation guide mapped to the
production codebase. It is a **design reference, not production code**.

Audience: an AI coding agent (or human) working inside the `Khayt` repo
(Electron + vanilla JS renderer) who is asked to "apply this design".

## The two directions

| | **A — Studio** | **B — Workshop Ledger** |
|---|---|---|
| Entry file | `Khayt Redesign.html` | `Khayt Alternative.html` |
| Mood | Dark engineered instrument | Warm paper + ink, industrial ledger |
| Default theme | Dark (`#0b0d12` blue-black) | Light paper (`#e9e4da`), dark "ink" variant |
| Accent | Filament Cyan `hsl(187 76% 53%)` | Safety Orange `hsl(24 88% 48%)` (alts: ultramarine, press green, cyan) |
| Navigation | **Grouped left sidebar** (Dashboard · Production · Sales · Business) | **Masthead + horizontal tab strip** with mono group labels (or compact icon rail) |
| Radii | Soft: 7 / 10 / 14 / 20 | Squared: 2 / 3 / 4 / 6 |
| Type | Hanken Grotesk + Geist Mono | Archivo + IBM Plex Mono |
| Source CSS/JSX | `khayt/` | `alt/` (+ shares `khayt/` screens) |

Both directions render the **same six screens** (Dashboard, Production Queue,
Calculator, Inventory, Analytics, Clients) from the same mock data
(`khayt/data.js`). Direction B reuses the screen components in `khayt/*.jsx`;
only its shell and CSS differ (`alt/`).

To view: open either entry HTML in a browser (needs its sibling folders).

## What's in this folder

```
Khayt Redesign.html       Direction A entry
Khayt Alternative.html    Direction B entry
khayt/                    Design system A + all six screens (JSX) + mock data + icons + charts
alt/                      Design system B: ds.css (tokens/utilities), shell.css, screens.css, shell.jsx
tokens/
  studio-tokens.css       Direction A tokens REWRITTEN with the app's variable names
  ledger-tokens.css       Direction B tokens REWRITTEN with the app's variable names
tweaks-panel.jsx          Prototype-only tweak controls — do NOT port
```

## How this maps to the production app

The app renderer is **vanilla JS + one big `renderer/index.html` +
`renderer/styles.css`**. The prototypes use React via in-browser Babel for
review only — **re-implement the markup/CSS in the existing vanilla renderer;
do not ship React or Babel.**

### 1. Tokens (the 80% step)

`renderer/styles.css` opens with `:root` / `[data-theme="light"]` token blocks.
Replace them with the contents of `tokens/studio-tokens.css` (A) **or**
`tokens/ledger-tokens.css` (B). They use the app's existing names (`--bg`,
`--bg-elev`, `--surface`, `--surface-2`, `--border`, `--border-soft`, `--text*`,
`--primary`, `--success`…, `--radius`, `--radius-sm`, `--shadow-*`,
`--font-sans`, `--font-num`), so most of the app restyles itself.

Rules that hold for BOTH directions:
- **Status colors never follow the accent** (success/warning/danger/info stay fixed).
- **All numerics use `--font-num`** with `font-feature-settings: "tnum" 1`
  (money, counts, percentages, IDs). See `.metric` / `.mono` in `*/ds.css`.
- Section labels ("eyebrows") are small uppercase, letter-spaced; Direction B
  sets them in the mono face.
- Direction B is light-first: ship with `<html data-theme="light">` default.

### 2. Fonts + CSP

`renderer/index.html` has CSP `default-src 'self'` — **Google Fonts links will
not load**. Vendor the woff2 files into `renderer/fonts/` and declare
`@font-face` locally:
- A: Hanken Grotesk (400–700), Geist Mono (400–600)
- B: Archivo (400–800), IBM Plex Mono (400–700)
- Both: IBM Plex Sans Arabic for `[lang="ar"]` / RTL.
The token files include system fallbacks, so this can land incrementally.

### 3. Shell / navigation

Current app shell: `.app > .titlebar + .header + nav.tabs (.tab-btn) +
main (.tab-content)`.

**Direction A** replaces the 13-tab strip with a grouped left sidebar:
- Reference markup/behaviour: `khayt/shell.jsx` (nav model `NAV`, groups
  Dashboard / Production / Sales / Business + Settings footer) and
  `khayt/shell.css` (`.khayt-sidebar`, `.khayt-navitem`, `.khayt-brand`).
- Keep `.titlebar` (drag region) as-is; move page title + search + "New order"
  into a top bar (`.khayt-top` reference).
- The existing `.tab-btn` click-routing can be reused — sidebar items are the
  same buttons restyled and re-laid-out; keep `data-i18n` keys and `role`
  attributes.

**Direction B** keeps the app's horizontal-tab paradigm (least structural
change) but upgrades it:
- Masthead above the tabs: brand block, global search, location select,
  Simple/Pro toggle, bell, primary "New order", user chip — reference
  `alt/shell.jsx` (`Masthead`) and `alt/shell.css` (`.alt-masthead`).
- Tab strip: active tab gets a 3px accent **underline** (not a filled pill);
  tiny uppercase mono group labels separate Production / Sales / Business —
  see `.alt-tabs`, `.alt-tab`, `.alt-tabgroup`.
- Each view starts with a page header row (`.alt-pagehead`): 24px title,
  muted subtitle, mono stamp on the trailing edge.

### 4. Component mapping

| App (styles.css) | Direction A reference | Direction B reference |
|---|---|---|
| `.card`, `.card-head` | `ds.css .card` (r-14, hairline border) | `alt/ds.css .card` (r-6, `--shadow-1` hard 1px) |
| `.btn` + variants | `ds.css .btn/.primary/.ghost/.subtle` | same names; B's `.primary` has a 2px offset hard shadow that "presses" on :active |
| `nav.tabs` / `.tab-btn` | replaced by sidebar (see §3) | `.alt-tabs` / `.alt-tab` |
| `table`, `.table-wrap` | `ds.css .tbl` (uppercase letter-spaced th) | `.tbl` with mono th + `--surface-2` header band |
| `.badge` | `.pill` / `.kbadge` | `.pill` (mono, uppercase, squared) |
| inputs/selects | `.input`, `.field`, focus ring `--accent-soft` | same, squared radius |
| dividers | `.thread` stitched dashed hairline — the brand motif (khayt = thread); use for card section breaks | same motif, kept |
| progress | `.meter` | `.meter` (bordered, squared) |
| KPI cards | `khayt/dashboard.jsx KpiCard` (eyebrow + 30px metric + spark) | same structure; B adds a 3px accent bar on the leading card edge (`.khayt-kpi::before`) |
| charts | `khayt/charts.jsx` — Spark/Ring/Bars, plain SVG, no deps; safe to port almost verbatim into vanilla JS | shared |
| icons | `khayt/icons.jsx` — 1.5px stroke, currentColor; export as inline SVG strings to satisfy CSP (`img-src 'self' data:` is fine, inline SVG preferred) | shared |

### 5. Screens

Each prototype screen corresponds to an existing renderer module:

| Prototype (`khayt/*.jsx`) | App module |
|---|---|
| `dashboard.jsx` | `renderer/dashboard.js` |
| `queue.jsx` (kanban) | `renderer/kanban.js` |
| `calculator.jsx` | `renderer/build.js` / `calculator-cost.js` |
| `inventory.jsx` | `renderer/inventory.js` |
| `analytics.jsx` | `renderer/analytics.js` |
| `clients.jsx` | `renderer/clients.js` |

The JSX is small and declarative — treat it as a markup spec (class names +
inline style intent), not code to transplant. All data in `khayt/data.js` is
mock; keep the app's real data flow and IPC untouched.

### 6. Do not break

- `data-i18n` attributes and the locale system (7 languages) — every visible
  string must keep/gain a key.
- `[dir="rtl"]` support — both prototypes use logical properties
  (`inset-inline-*`, `margin-inline-*`); keep that pattern.
- Theme toggle (`data-theme` on `<html>`), location filter, operator lock,
  notification bell, ⌘K search — restyle, never remove.
- CSP: no remote scripts/styles/fonts, no inline event handlers beyond what
  exists.

### 7. Suggested order of work

1. Land token swap (`tokens/*.css`) behind the existing theme system.
2. Vendor fonts + `@font-face`.
3. Restyle shared primitives (.btn, .card, table, .badge, inputs, .thread).
4. Rebuild shell/nav per chosen direction.
5. Screen-by-screen polish against the prototype (dashboard → queue → …).
6. RTL + light/dark pass, then locale sweep.
