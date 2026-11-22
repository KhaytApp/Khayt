# UI Redesign — status

**Status: shipped (Khayt 2.6).** The 7-theme set was replaced by **3** redesigned,
light-default themes with a native-app feel: **Workbench** (default), **Command**,
and **Vivid**. Screen interiors were rebuilt to match the approved prototypes
(not just a chrome re-skin). The older themes remain selectable as legacy options.

## What shipped
- **Workbench** is the default design (`settings.designTheme: 'workbench'`).
  Saved `studio` / `ledger` / `console` selections migrate to Workbench on upgrade.
- **Command** and **Vivid** ship alongside it (all light by default), each with its
  own shell/tokens.
- Every screen interior (Dashboard, Calculator → order, Production Queue/Kanban,
  Fleet, Inventory, Clients, Orders/Invoices, Analytics, Settings, Waste, Catalog,
  Portfolio, Gift Cards) is rebuilt per theme, with dark + RTL (Arabic) variants.
- README screenshots are captured from the Workbench theme with demo data
  (`npm run capture:screenshots`); per-theme galleries via
  `node scripts/capture-theme-screenshots.mjs`.

## How it's built (reference)
- Theme definitions: `renderer/themes/registry-core.js` (`BUILTIN_THEMES`).
- Per-theme chrome + screens: `renderer/themes/<theme>/{tokens,shell,screens}.{css,js}`.
- Each theme exposes `Khayt<Theme>.render<Screen>(host)`; the shared
  `render<Screen>()` delegates when the theme's `body.khayt-<theme>` class is set
  (mirrors the original `KhaytStudio` pattern). Other themes are untouched.
- Prototypes (design targets): `design/proto-a-workbench.html`,
  `design/proto-b-cockpit.html`, `design/proto-c-vivid.html` (proposal in
  `docs/UI-REDESIGN.md`).

## Verify locally
`npm install` then `npm start`. The app opens in Workbench; switch via
**Settings → Preferences → Design**. To re-capture screenshots, run
`npm run capture:screenshots` (output in `assets/screenshot-*.png`).
