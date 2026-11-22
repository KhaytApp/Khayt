# Accounting export — invoices & expenses to QuickBooks / Xero / Zoho Books

**Scope:** export a date-ranged set of invoices and expenses to the shop's accountant — as a generic CSV and as provider-specific files (QuickBooks IIF/CSV, Xero CSV, Zoho Books CSV), with an **optional** direct-API push later. Implements the bookkeeping-handoff item on the [3.0 roadmap](./KHAYT-3.0-ROADMAP.md).

**Governing principle:** **File-first, offline, API optional.** Mode (a) — file export — is the baseline: it runs entirely locally, needs no account and no internet, and produces a file the owner emails or uploads to their accountant. Mode (b) — direct API sync — is strictly opt-in, off by default, and degrades to "hidden/disabled" with no keys (same stance as ZATCA Phase 2 / SMTP / BNPL). The export never invents numbers: every figure comes from the existing store, the same way the invoice and tax-summary code already reads it.

---

## 1. What's exported

- **Invoices** — completed/delivered orders in `printLog`. Per row: invoice number (`order.invoiceNumber || order.id`), date, client, project, **VAT-inclusive total** (`order.price`), and the derived **subtotal (ex-VAT)** + **VAT amount** + **VAT rate**, computed exactly as `zatcaInvoiceAmounts(order)` does — `vatAmt = price * rate / (100 + rate)`, `rate = settings.enableVat ? (settings.vatRate || 15) : 0`. Currency is `clientCurrency(order.clientId)`.
- **Credit notes** — each entry in `order.creditNotes[]` (`id`, `amount`, `reason`, `issuedAt`) exports as a separate **negative** document referencing the original invoice number, mirroring `generateCreditNote`. These are refunds / cancelled charges, not payments.
- **Milestone invoices** — issued milestones (`order.milestones[]` with `issuedAt`) export as their own invoice lines at `milestone.amount`, referencing the parent order, matching `generateMilestoneInvoice` (no re-billed shipping/rush/extras).
- **Expenses** — every `expenses[]` record: `date`, `category` (mapped to an account name), `amount`, `note`, `orderId`, and a `receiptPath`/`attachedFiles` reference (filename only — the file itself is not embedded).
- **Date-range selection** — reuse the **period-selector modal** from `exportTaxSummary` (this-month / last-month / this-quarter / last-quarter / year / all / custom from–to), and its `inPeriod(dateStr)` filter.

## 2. Formats

Every file is UTF-8 with a BOM and `\r\n` rows (matching `exportExpensesCsv` / `_doExportTaxSummary`); cells escaped via the existing `csvEsc`. Round-tripping/import validation uses `parseCsvString` from `util.js`.

**Generic CSV (baseline, always available):** two files — `invoices.csv` and `expenses.csv` — with stable, documented headers. This is the zero-dependency fallback the accountant can open anywhere.

**Per-provider field mapping (invoices):**

| Khayt field | QuickBooks (IIF/CSV) | Xero (Sales CSV) | Zoho Books (Invoice CSV) |
|---|---|---|---|
| `invoiceNumber` | `RefNumber` / Invoice No | `InvoiceNumber` | `Invoice Number` |
| `date` | `Date` | `InvoiceDate` | `Invoice Date` |
| client name | `Name` (Customer) | `ContactName` | `Customer Name` |
| `project` / item | `Memo` / line `Desc` | `Description` | `Item Name` |
| subtotal ex-VAT | line `Amount` (net) | `UnitAmount` | `Item Price` |
| VAT amount | `TaxAmt` | `TaxAmount` | `Tax Amount` |
| VAT rate | tax line item | `TaxType` (e.g. `Tax on Sales`) | `Tax Percentage` |
| total incl. VAT | `Amount` (TRNS) | `Total` (derived) | `Total` |
| currency | `Currency` | `Currency` | `Currency Code` |
| credit note | negative `Amount` / Credit Memo | negative line / Credit Note | Credit Note row |

**Per-provider field mapping (expenses):**

| Khayt field | QuickBooks | Xero (Bills/Purchases CSV) | Zoho Books (Expense CSV) |
|---|---|---|---|
| `date` | `Date` | `Date` | `Expense Date` |
| `category` | `Account` | `AccountCode` | `Expense Account` |
| `amount` | `Amount` | `UnitAmount` | `Amount` |
| `note` | `Memo` | `Description` | `Description` |
| `orderId` | `Memo` ref | `Reference` | `Reference#` |

A small per-provider account map (e.g. `filament → "Cost of Goods Sold"`, `electricity → "Utilities"`) lives in a config table; unmapped categories fall back to the raw category string so nothing is dropped.

## 3. Optional API push (Mode b)

- **Settings → Accounting integrations** (new, opt-in, off by default), one card per provider. Connect via **OAuth 2.0** through the main process (browser-based consent, same `hubAPI`/IPC pattern as other network calls); store the refresh token + client secret with the **existing encrypted-secret pattern**.
- **Secret redaction:** add the new keys to `redactSettingsForExport` in `store.js` (e.g. `mask(s.accounting?.quickbooks, 'refreshToken')`, same for `xero`/`zoho` client secrets/tokens) so they never leave in a `buildExportPayload({ redactSecrets:true })` snapshot.
- **Push** reuses the exact same in-memory rows the file exporter builds, then POSTs to each provider's invoice/expense endpoint; success/error logged per row like `appendZatcaSubmissionLog` (status, timestamp, message, dedupe on already-synced).
- **No keys → the API card is hidden/disabled; file export is unaffected.** Graceful degradation, no crash.

## 4. Integration points (existing code to reuse)

- `renderer/store.js` — `buildExportPayload` structure + `redactSettingsForExport` (extend for new secrets).
- `renderer/util.js` — `parseCsvString` (import/validation), and follow the `csvEsc` + BOM + `\r\n` convention.
- `renderer/expenses.js` — `exportExpensesCsv`, `exportTaxSummary` / `_doExportTaxSummary` (period modal, `inPeriod`, `downloadBlob`), `EXP_CATEGORIES`, `expCatLabel`.
- `renderer/invoicing.js` — `zatcaInvoiceAmounts(order)` (VAT split), `generateCreditNote` (`creditNotes[]`), `generateMilestoneInvoice` (`milestones[]`).
- `renderer/currency.js` — `convertToBase`, `clientCurrency`, `orderRevenueBase`, `orderOwedBase`, `CURRENCIES`.
- `renderer/app-exports.js` — new sibling exporter module; mirror its `buildExportPayload`-driven structure.

## 5. Edge cases

- **Multi-currency:** export the invoice in its **native** `clientCurrency` (provider field carries the code) **and** a base-currency column via `convertToBase`, so SAR-base books still reconcile. Never silently coerce; if `exchangeRates` lacks a rate, `convertToBase` returns the raw amount — flag such rows in a warning summary rather than dropping them.
- **VAT rounding:** compute VAT once per invoice as `price * rate/(100+rate)`, round to 2 dp with `Math.round(x*100)/100` (same as `buildZatcaInvoiceXml`'s `amt()`), and ensure `subtotal + vat == total` after rounding; reconcile the rounding penny onto the subtotal line so providers don't reject the document.
- **Credit notes / refunds:** emit as negative documents linked to the original invoice; never net them into the original total. Fully-credited orders (`order.creditedAt`, `totalCredited >= price`) export the invoice **and** an offsetting credit note.
- **Partial payments:** the invoice exports its full face value (VAT-inclusive total); payment state (`paidAmount`, `orderOwedBase`) is **not** an accounting document and is excluded — the accountant records receipts on their side. Optionally include a non-exported "outstanding" column in the generic CSV only.
- **VAT off / zero-rated:** `settings.enableVat === false` → `rate = 0`, VAT columns emit `0.00`, no tax line.

## 6. Test plan & Definition of Done

- **VAT split:** fixed order → exported subtotal/VAT/total match `zatcaInvoiceAmounts`; `subtotal + vat === total` after 2-dp rounding (including a value that rounds awkwardly, e.g. price 100.00 @ 15%).
- **Date range:** custom from–to via the reused period modal includes/excludes the right invoices and expenses.
- **Credit note:** order with a `creditNotes[]` entry → original invoice + a negative credit-note row referencing it; full credit → both rows present.
- **Milestone:** issued milestone → its own row at `milestone.amount` linked to the parent; no re-billed shipping/rush.
- **Multi-currency:** non-base client → native + base columns; missing exchange rate → row flagged, not dropped.
- **CSV integrity:** generic output re-parses cleanly with `parseCsvString`; commas/quotes/Arabic text survive (`csvEsc` + BOM).
- **No-keys / offline:** file export works with zero accounts and no network; API cards hidden.
- **Secret handling:** new OAuth tokens masked in UI and redacted from `buildExportPayload({ redactSecrets:true })` (extend existing secret tests).

**DoD:** from a date range, the owner produces a generic CSV plus at least one provider file (QuickBooks/Xero/Zoho) that imports cleanly, with correct VAT, credit notes, and multi-currency, **fully offline and with no account**. Optional API push, when configured, syncs the same rows and degrades to hidden with no keys. No secret ever leaves in an export.
