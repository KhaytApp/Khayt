# Khayt — Production Studio · Redesign Package

A high-fidelity redesign of the Khayt desktop app UI. This is a **design prototype
and reference spec** — not production renderer code. Use it to drive the port into
the Electron `renderer/`.

## What's here

```
Khayt Redesign.html      Entry point — open in any browser
khayt/
  ds.css                 Design system: tokens, type, color, buttons, inputs, tables
  shell.css              Window chrome, grouped sidebar, top bar
  screens.css            Per-screen component styles
  icons.jsx              Line-icon set (stroke, currentColor)
  charts.jsx             Spark / Ring / Donut / Bars SVG primitives (no deps)
  data.js                Mock shop data (printers, orders, filaments, clients…)
  dashboard.jsx          Dashboard screen
  queue.jsx              Production Queue (Kanban)
  calculator.jsx         Cost calculator + live breakdown
  inventory.jsx          Filament & resin stock
  analytics.jsx          Revenue / machine P&L / heatmap
  clients.jsx            CRM & loyalty
  shell.jsx              App shell: nav model, routing, Tweaks wiring
tweaks-panel.jsx         In-prototype tweak controls (theme/accent/density/RTL)
dist/
  Khayt-Redesign-standalone.html   Single self-contained file (works offline)
```

## Design system at a glance

**Brand color** — Filament Cyan, sampled from the app icon (the glowing خ being
printed). Driven by three CSS vars so the hue is swappable:
`--accent-h: 187; --accent-s: 76%; --accent-l: 53%;`

Logo-family accent options (all cool register):
Filament Cyan · Deep Teal · Bed-Glow Aqua · Print Sky · Azure.

**Status colors are independent of accent** (never recolor these):
ok `#3fb87f` · warn `#e0a93c` · danger `#e5544b` · info `#5b9cf0` · violet `#9a86f5`.

**Surfaces (dark, default):**
bg `#0b0d12` · surface `#14181f` · surface-2 `#1a1f28` · border `rgba(255,255,255,.07)`.
A warm-paper light theme lives under `[data-theme="light"]`.

**Type:** Hanken Grotesk (UI) · Geist Mono (all numerics, tabular) ·
IBM Plex Sans Arabic (RTL). Numbers use `font-feature-settings: "tnum" 1`.

**Spacing** scales off `--u` (4px base); density tweaks multiply it.
**Radii:** xs 5 / sm 7 / md 10 / lg 14 / xl 20.

## The core fixes (vs. current app)

1. **De-clutter** — the 13-tab horizontal bar → a grouped left sidebar
   (Dashboard · Production · Sales · Business · Settings). Only ~5 peers compete.
2. **De-basic** — engineered instrument aesthetic: tabular mono numerics, real
   type hierarchy, stitched-hairline "thread" dividers, authentic glowing-glyph mark.

## Notes for production

- The prototype uses React via **in-browser Babel** — fine for review, **do not ship
  it that way**. Either precompile the JSX or re-implement the markup in the existing
  vanilla `renderer/index.html`.
- All data is mock (`khayt/data.js`). Wire screens to the real data/IPC layer.
- Tweaks panel is a design exploration tool, not an app feature.

## How to view

Open `Khayt Redesign.html` (needs its `khayt/` folder beside it) or, for a
zero-setup single file, open `dist/Khayt-Redesign-standalone.html`.
