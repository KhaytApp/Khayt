# Contributing to Khayt

Thank you for helping maintain Khayt. This document is the default workflow for changes landing in this repository.

## Prerequisites

- **Node.js 22+** (matches release CI and README)
- `npm ci` then `npm start` for local Electron development

## Branching

- `main` — stable; release tags are cut from here.
- Feature/fix branches: `cursor/<short-description>-c86e` or `fix/<topic>`, `feat/<topic>`.

## Before you open a PR

1. Run syntax checks and unit tests (same as CI):

   ```bash
   npm run lint
   npm test
   ```

   Optional headless UI smoke (requires display / `xvfb-run` on Linux):

   ```bash
   npm run test:e2e
   ```

   E2E covers boot, tab navigation, order lifecycle, store round-trip, and LAN PIN gate.

2. If you changed user-visible behavior, add a line under `CHANGELOG.md` → `[Unreleased]`.

3. Bump version only when preparing a **release** (see [VERSIONING.md](./VERSIONING.md)), not on every PR.

## Contributor License Agreement (required)

Khayt is offered under both a source-available license ([FSL-1.1-Apache-2.0](./LICENSE))
and a commercial license. So contributions can be carried in both, every contributor
agrees to the [Contributor License Agreement](./CLA.md) by signing off their commits
with the Developer Certificate of Origin:

```bash
git commit -s -m "your message"   # adds: Signed-off-by: Your Name <email>
```

The `Signed-off-by` line certifies you wrote the change (or may submit it) and that
you agree to the [CLA](./CLA.md) for that contribution. PRs without a sign-off can't
be merged. Don't paste in code under a license incompatible with the CLA (e.g.
GPL/AGPL).

## Pull requests

- One logical change per PR when possible.
- Describe **what** changed and **why**.
- For bugs: steps to reproduce, expected vs actual.
- Screenshots for UI changes (light and dark if relevant).

## Code areas

| Path | Role |
|------|------|
| `main.js` | Electron main: IPC, disk store, LAN server, ZATCA crypto, updater |
| `preload.js` | `hubAPI` context bridge |
| `renderer/app.js` | UI and business logic |
| `renderer/store.js` | Export/import and backup helpers |
| `renderer/format.js` | Number, money, CSV, and unit-price helpers |
| `renderer/util.js` | DOM, storage, dates, HTML escape, CSV parse |
| `renderer/currency.js` | Currency catalogue and conversion |
| `lib/calculator-cost.js` | Part costing (`computePartBaseCost`, tiers, breakdown) |
| `renderer/kanban.js` | Production queue board, machine queues, drag-reorder |
| `renderer/invoicing.js` | Invoice/quote render, ZATCA, PDF export, credit notes |
| `renderer/i18n.js` | Translations |
| `renderer/studio/*.js` | Khayt Studio UI module |
| `lib/` | Shared main-process helpers (`safeJsonParse`, `isBlockedHost`) |
| `test/` | `node:test` unit tests for `lib/` |
| `design/khayt/` | UI design prototype (reference only, not shipped) |

The desktop app uses `renderer/index.html` as its shell; there is no root Vite scaffold.

## Releases (maintainers)

See [VERSIONING.md](./VERSIONING.md). Summary: update `CHANGELOG.md` → `npm run version:patch|minor|major` → commit → tag `vX.Y.Z` on `main` → push tag to trigger installers.

## Security

Report sensitive issues privately to **support@khaytapp.com** rather than a public issue if exploitation is possible (LAN API, store format, ZATCA keys).
