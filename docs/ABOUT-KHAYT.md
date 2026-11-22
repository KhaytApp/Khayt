# Khayt — a description you can hand to an AI

Paste the block below as context. It is written to be pasted whole; trim the
last two sections if you only need the product, not the engineering.

---

## What Khayt is

Khayt is desktop software that keeps a 3D printing shop's book. Not a printer
monitor and not a generic ERP — the business itself: the jobs a shop has taken,
what each one actually cost, what was charged, what is on the shelf, what the
printers are doing, and what any of it earned.

It is free, works fully offline, and stores everything in one JSON file on the
shop's own machine. An optional end-to-end encrypted cloud syncs that file
between machines and gives customers a page to follow their order on; nothing
requires it.

## Who it is for

Small and mid-sized print shops — roughly one to twenty machines. Above that,
enterprise MRP; below it, a spreadsheet. Built first for a Saudi shop, which is
why the tax and language work are load-bearing rather than decorative.

## What it does

- **Jobs** — take work, move it through pending → printing → post-processing →
  QC → completed → delivered, on a table or a kanban board.
- **Money** — quotes, invoices, part payments and deposits, expenses, failed
  prints costed as waste. Revenue is held net of tax throughout.
- **Tax** — VAT by country, and full ZATCA e-invoicing for Saudi Arabia:
  bilingual invoice, QR code, the lot.
- **Inventory** — spools with what is left on them, run-out forecasting, drying
  flags, QR labels. Filament is deducted from the spool when a job records what
  it actually used.
- **Library** — the models a shop prints, as a grid, with folder-derived groups,
  Quick Look, duplicate detection by file contents.
- **Catalogue** — products with a price whose provenance is always stated
  (typed, rounded-from, or calculated).
- **Machines** — seven printer protocols watched live (Moonraker/Klipper,
  OctoPrint, PrusaLink, Duet, Repetier, Bambu, Elegoo SDCP), with pause, resume,
  cancel, and dropping one object from a running plate on Klipper.
- **Reports** — P&L, aged receivables, break-even, cash flow, client lifetime
  value, quote funnel, machine profitability per hour, first-pass yield.
- **Also** — a 3MF converter between slicer ecosystems, a colour studio,
  gift cards, customer records, backups and restore.

## What makes it different

Three things, in order of how hard they are to copy:

1. **Arabic is a first-class language, not a translation.** The whole interface
   mirrors right-to-left. Nine languages ship (ar, de, en, es, fr, ja, pt-BR,
   tr, zh) and switch instantly. Products and customers carry one field per
   language rather than one field.
2. **ZATCA compliance.** No other 3D-print shop tool has it.
3. **Offline-first and free.** The competition is cloud-only and subscription.

## What it is not

Not a slicer. Not a print-farm monitor that happens to have invoicing bolted on
— the queue exists because jobs have customers and prices behind them. Not a
hosted web app.

## The competition, honestly

- **FoxTrack** ($9/mo, web) — the closest rival; orders, quotes→invoices,
  inventory, printers. No tax regime.
- **PrintFleet** (cloud) — quoting and cost-per-job. No invoicing at all.
- **SimplyPrint**, **OctoPrint**, **Spoolman**, **OctoFarm** — printer and
  filament monitoring; no business side.
- **NetSuite / Odoo** — enterprise-priced and the wrong shape for a print shop.

The gap Khayt sits in: monitoring tools do not do the business, and business
tools do not know what a print costs.

---

## For engineering context

- **Two apps, one book.** A native macOS app (SwiftUI; this is the primary
  product going forward) and an Electron app for Windows and Linux (secondary).
  Both read and write the same store file. One writes at a time, enforced by a
  lock — two writers is how a shop loses an afternoon.
- **The business rules are shared JavaScript.** ~240 dependency-free modules in
  `lib/` — tax, pricing, payment plans, split orders, loyalty, the estimator.
  The Mac app runs them unchanged in JavaScriptCore rather than reimplementing
  them in Swift, and a differential suite proves the two agree. Reimplementing
  `computeTax` in Swift would earn the right to be wrong in a second way.
- **Tested heavily.** ~4,450 Node tests and ~1,080 Swift tests, and the culture
  is that a test encodes the defect it was written for, in prose, next to the
  assertion.

## House style, if you are writing code for it

- Comments explain **why**, and name the real failure that motivated the rule —
  not what the line does.
- A guard is written the positive way round, so new code is excluded by default
  rather than included by accident.
- A correct module with no caller is the recurring defect; wire it and pin the
  wiring with a test.
- Never write a rule twice. If Swift and JavaScript both need it, it goes in
  `lib/`.
