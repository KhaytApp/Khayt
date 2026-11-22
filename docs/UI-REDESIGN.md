# Khayt UI Redesign — Proposal (v2.7 "Atlas-Practical")

A more practical, user-friendly UI. Grounded in the cross-domain UI/UX scan
(workflow friction, inverted action naming, fragmented settings-save, data
density, 13 flat nav items, inconsistent control language across 7 themes).

Sequence: **proposal (this doc) → clickable prototype → in-app build**.

---

## 1. Problems we're solving (from the scan)

| # | Problem | Today |
|---|---------|-------|
| P1 | **Nav sprawl** | 13+ flat sidebar items (dashboard, calculator, queue, inventory, clients, expenses, waste, gift-cards, logs, analytics, portfolio, catalog, settings) — no grouping, hard to scan. |
| P2 | **Unclear primary action** | The money flow's main button was mislabeled ("Save quote" actually created an order). Primary vs secondary actions aren't visually ranked. |
| P3 | **Fragmented save model** | Settings mixes one big Save, auto-save, and ~7 per-section Saves with inconsistent toasts. |
| P4 | **Data density / no states** | Tables clip, no empty/loading states in several tabs, dashboard scans the whole dataset synchronously. |
| P5 | **Inconsistent components** | `btn small` vs `btn sm`, button radius 2px→100px across themes, terminology drift (Outstanding/Receivables/Has balance). |
| P6 | **Discovery** | Power features (shortcuts, Professional-only sections) are hidden; no in-app search of settings. |

## 2. Design principles

1. **One job per screen, one obvious next action.** Every screen ranks a single primary action; destructive actions are guarded + undoable (shipped).
2. **Group, don't list.** Collapse 13 items into 4 task-based groups + a command palette.
3. **Progressive disclosure.** Simple mode shows the essentials; Professional reveals more — with a visible hint, not a hard hide.
4. **One component language.** A single token scale (spacing, radius, weight, control height) all themes share; themes override *color/texture only*.
5. **Calm density.** Consistent cards, generous-but-tight spacing, sticky table headers, real empty/loading states.
6. **Keyboard-first, mouse-friendly.** ⌘K command palette is the spine of navigation and actions.

## 3. Information architecture (P1)

Collapse to **4 task groups** + pinned Dashboard + Command palette:

```
◇ Dashboard            (home / daily cockpit)
─ WORK ────────────────
  Calculator           (quote/order builder)
  Queue                (kanban + production)
  Fleet                (printers, live)               ← surfaces existing telemetry
─ CATALOG ─────────────
  Inventory            (filament/consumables, per-location)
  Machines
  Clients
─ MONEY ───────────────
  Invoices & Orders    (was "Logs" — renamed to what it is)
  Expenses
  Analytics            (waste + P&L + gift cards folded in as tabs)
─ SHrunk into headers ─
  Intake / Waiting     (badge on Queue, not a separate item)
  Portfolio            (tab under Clients)
⌘K  Command palette    (jump to anything + run actions)
⚙   Settings           (bottom-pinned)
```

Net: **13 flat items → 4 groups of ~3**. Gift cards, waste, portfolio become tabs inside their parent rather than top-level noise.

## 4. Shell layout

```
┌───────────────┬─────────────────────────────────────────────┐
│  KHAYT        │  Dashboard            🔍 ⌘K   ◐  🔔  👤 EN ▾ │  ← top bar: page title + global search + utilities
│  ◇ Dashboard  ├─────────────────────────────────────────────┤
│               │  [ location: All ▾ ]      [ + New order ]    │  ← context bar: active filters + screen primary action
│  WORK         │                                              │
│   Calculator  │   ┌─ card ─┐ ┌─ card ─┐ ┌─ card ─┐           │
│   Queue       │   │  KPI   │ │  KPI   │ │  KPI   │           │
│   Fleet       │   └────────┘ └────────┘ └────────┘           │
│  CATALOG      │   ┌─ Today's work ──────┐ ┌─ Fleet ───┐      │
│   Inventory   │   │ …                   │ │ ▮▮▮ live  │      │
│   Machines    │   └─────────────────────┘ └───────────┘      │
│   Clients     │                                              │
│  MONEY        │                                              │
│   Invoices    │                                              │
│   Expenses    │                                              │
│   Analytics   │                                              │
│               │                                              │
│  ⚙ Settings   │                                              │
└───────────────┴─────────────────────────────────────────────┘
```

- **Top bar**: page title (left), centered global search (⌘K), utilities right (theme, notifications, operator, language). The language/location selects move into a tidy menu so they stop crowding the bar.
- **Context bar** (new): per-screen — left = active filters (location, status), right = the screen's **single primary action** (`+ New order`, `+ Add spool`…). This fixes P2: the primary action is always in the same place, clearly ranked.
- **Collapsible sidebar** with the grouped IA; collapses to icons on narrow windows.

## 5. Key flow redesigns

### Calculator → Order (P2)
- Two clearly-ranked actions: **`Create order →`** (primary, filled) and **`Save as quote`** (secondary, outline). Labels say what they do (shipped in #100).
- A persistent **build summary rail** (parts, cost, margin, price) so the number is always visible while editing.
- Confirm before the destructive "create + clear" (shipped).

### Queue (P4)
- Kanban with **cross-column drag = status change** (today drag only reorders); sticky column headers; per-status empty messages.
- Intake/waiting surfaces as a **badge + slide-over** on Queue, not a separate nav item.

### Inventory (per-location, just built)
- Location scope banner + per-row location chip; transfer + label actions in a row `⋯` menu (not 8 inline buttons).

### Settings (P3)
- **One model: auto-save on change**, with a single persistent "Saved ✓ / Saving…" indicator in the section header. No more mixed Save buttons.
- A **settings search** box; Professional-only sections shown with a "More in Professional" hint instead of hidden.

## 6. Component & token system (P5)

A shared core all themes consume; themes override **color/texture only**:

```
--space: 4 / 8 / 12 / 16 / 24 / 32          (one spacing scale)
--radius: 6 (controls) / 10 (cards) / 999 (pills)   (per-theme may scale, not redefine)
--control-h: 34px   (one height for inputs, selects, sm buttons → fixes the clipped dropdowns)
--font-weight: 600 (label) / 700 (heading)
Buttons: one class `.btn` + `.btn--primary|ghost|danger` + `.btn--sm`  (kill `small`/`sm` split)
Cards: one `.card` with header/body/footer slots
States: `.is-empty`, `.is-loading` (skeleton) standardized
```

Terminology lock: pick **one** word per concept (e.g. **Outstanding** everywhere, **Invoices & Orders** not "Logs/Database").

## 7. Accessibility & i18n (carry forward)

- Logical CSS properties throughout (RTL-correct), label↔input pairing, `aria-current`, focus-visible rings, focus trap (shipped).
- Full en + ar parity (gated).

## 8. Migration / how it ships

- Build it as a **new theme/shell** in the existing registry (the reserved 8th slot), **not** a rip-and-replace — opt-in via the theme picker, so current users are undisturbed while the new UI is validated in beta.
- Reuse the existing renderer modules and data layer; the redesign is shell + component-language + IA, not a logic rewrite.
- Roll out: prototype → new shell behind the picker (beta.2/beta.3) → make default in 2.7 stable once validated.

## 9. Open decisions for you

1. **Name** for the new design (suggestions: *Studio 2*, *Workbench*, *Flow*).
2. Default **density** (comfortable vs compact).
3. Keep all 7 existing themes + add this as the 8th, or position it to **replace** Studio as the default?
4. Light-first or dark-first default.

---

*Next: a self-contained HTML prototype implementing §4–§6 with mock data (openable in a browser), then the in-app build as a new shell.*
