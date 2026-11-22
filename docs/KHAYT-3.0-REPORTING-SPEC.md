# Reporting builder & scheduled reports — spec

**Scope:** let owners build **custom reports** (metric + dimension + filter + date range) and **dashboards** beyond the fixed Analytics tab, and **schedule recurring report emails** by extending the existing email digest. Implements [roadmap](./KHAYT-3.0-ROADMAP.md) reporting line. **Local-first, opt-in.** Optional AI tie-in (BYO key) for natural-language report building, consistent with [AI spec §6](./KHAYT-3.0-AI-SPEC.md).

---

## 1. Governing principle

**Build on the existing compute; don't rebuild analytics.** `renderer/analytics.js` already computes every measure we need (revenue, P&L, SLA, LTV, retention, break-even, aged receivables, utilization, NPS, …) over the global fact arrays (`printLog`, `clients`, `products`, `machines`, `expenses`, `inventory`, `operators`, `timeEntries`, `locations`, `suppliers`). A **report is a saved *definition*** (`metric + dimension + filter + dateRange + viz`) that is **rendered from that same computed data** — never a second analytics engine. **Scheduled delivery reuses the digest scheduler and `hub:send-email` path** — we extend it, we do not add a second mailer. Currency normalization always goes through `orderRevenueBase` / `convertToBase` into `settings.currency`; VAT is derived inclusive (`price * rate / (100 + rate)`), never stored separately.

---

## 2. Data model

New nested settings collection `settings.reports` (merge-on-load array, same pattern as `emailDigest` in `app-state.js`):

```js
// a saved report definition
{
  id, name, nameAr,                 // localized title
  metric,                           // one measure key (see §3) — e.g. 'revenue'
  dimension,                        // one group-by key (see §3) — e.g. 'month' | null (single KPI)
  filters: {                        // optional, all AND-ed
    clientId?, productId?, machineId?, locationId?, operatorId?,
    status?, source?, tags?[], paid?  // paid: 'paid'|'unpaid'|'partial'
  },
  dateRange: 'month'|'last_month'|'quarter'|'year'|'all'|{from,to},  // reuse analytics ranges
  viz: 'bar'|'line'|'table'|'kpi'|'pie',
  createdAt, updatedAt
}
```

```js
settings.reports = { definitions: [ /* …above… */ ], dashboards: [ /* §7 */ ] };
```

**Schedule** lives on the digest object (extend it), not duplicated per report:

```js
settings.emailDigest = {
  enabled, frequency:'daily'|'weekly', hour, weekday, recipientEmail, lastSentDate,  // EXISTING
  reportIds: [],                    // NEW — which saved reports to include (empty = legacy fixed digest)
  format: 'email'|'pdf'|'csv',      // NEW — body inline (default), or attach
}
```

Reuse keys exactly; `lastSentDate` dedupe (`YYYY-MM-DD` / `YYYY-Www`) is unchanged.

---

## 3. Available metrics & dimensions (derived from `analytics.js`)

**Metrics** (each maps to an existing compute, listed here so the builder offers only real measures):

- `revenue` (`orderRevenueBase`), `orders` (count), `aov` (avg order value), `outstanding` (`orderOwedBase`)
- `netProfit` / `pnl`, `grossMargin%`, `vatCollected` (`renderPnLSection`), `breakEvenRevenue` (`computeBreakEven`)
- `slaOnTime%`, `avgDelayDays` (`renderSLASection`)
- `clientLtv`, `repeatRate`, `retention30/60/90` (`renderClientLtvTable`, `renderClientRetention`, `renderNewVsReturning`)
- `agedReceivables` (buckets, `renderAgedReceivables`)
- `leadTimeDays`, `cycleTimeDays`, `throughput`
- `npsScore`, `avgRating` (`renderSurveyAnalytics`)
- `printHours`, `utilization%`, `capacityBooked` (`renderPrinterUtilizationChart`, `computeCapacityForecast`)
- `downtimeHours`, `maintenanceCost`, `timeAccuracy%`
- `expenseTotal`, `cashCollected`, `revPerPrintHour`, `materialCostPerGram`, `wasteWeight`
- `laborCost`, `laborHours` (time-tracking)

**Dimensions** (group-by, all already emitted): `month`, `day`, `quarter`, `dayOfWeek×hour`, `machine`, `client`, `clientCohort`, `product`, `location`, `expenseCategory`, `source`, `operator`, `order`, `materialType`, `starRating`, `agingBucket`. `null` dimension ⇒ single-value KPI.

Implementation: extract the per-record aggregation out of each `render*` into a thin `computeMetric(metric, dimension, filters, range)` registry in a new `renderer/reporting.js`, **calling the existing helpers** (`inRange`, `orderRevenueBase`, `computePartBaseCost`, `payStatus`). Not every metric supports every dimension — the registry declares valid `(metric × dimension)` pairs; the builder greys out invalid combos.

---

## 4. Report builder UX

New **Reports** subtab (Professional mode; hidden in Simple mode where `renderSimpleReports` stays). Three-step inline builder:

1. **Pick a metric** (dropdown grouped: Revenue / Profitability / Clients / Operations / Quality).
2. **Group by** a dimension (only valid pairs shown) — or "none" for a KPI card.
3. **Filter & range** — client/product/machine/location/status/tag/paid + a date-range picker reusing the analytics ranges plus a custom `{from,to}`.

A **live preview** renders immediately via `computeMetric(...)` + the chosen `viz`, reusing existing SVG bar/line builders and table markup (`fmtPrice`, `fmtMoney`, `currencySymbol`). **Save** stores the definition; saved reports list with run / edit / duplicate / delete / "export CSV" / "add to dashboard". No new charting library — viz reuses analytics' inline SVG patterns.

---

## 5. Scheduled reports (extend the existing digest)

The digest scheduler is untouched: `setInterval(checkAndSendDigest, 5*60*1000)` in `app-boot.js`; `checkAndSendDigest()` in `integrations.js` gates on hour/weekday + `lastSentDate`. We change only **what content it builds**:

- `renderDigestSettings()` (settings.js) gains: a **multi-select of saved reports** (`reportIds`) and a **format** radio (email-inline / PDF attach / CSV attach). Empty `reportIds` ⇒ current fixed digest (back-compat).
- `buildDigestEmailHtml()` gains a branch: if `reportIds.length`, render each selected report (via `computeMetric` → HTML table/inline-SVG) into the email body, localized, in base currency.
- Recipients & cadence reuse the existing `recipientEmail` / `frequency` / `hour` / `weekday`. Test-send button reuses `window.hubAPI.sendEmail`.

**Attachments (PDF/CSV) require new plumbing** — the current path is HTML-body-only end to end. Extend the IPC payload `hub:send-email` (`main.js`) with an optional `attachments:[{filename, mimeType, contentBase64}]`, and emit `multipart/mixed` in all three branches (SendGrid `attachments`, Mailgun, and `sendCustomSmtp`/`smtpDialog` in `lib/custom-smtp.js`). CSV reuses the `csvEsc`/BOM/`\r\n` convention from `app-helpers.js`; PDF reuses `window.hubAPI.exportPDF`. If attachment plumbing is descoped from v1, ship **email-inline only** and gate PDF/CSV behind a follow-on.

---

## 6. Dashboards

A **dashboard** is an ordered list of saved-report ids arranged in a grid (`settings.reports.dashboards = [{ id, name, nameAr, tiles:[{reportId, w:1|2}], order }]`). Owner picks saved reports → drag to arrange → set 1- or 2-column width. Rendered by iterating tiles and calling the same `computeMetric` + viz used in preview. A dashboard can be set as the default Analytics landing view. No new compute — pure composition of saved definitions.

---

## 7. AI tie-in (optional, BYO key)

Per AI spec §6, **opt-in, off by default, hidden with no key**. Natural-language → **report definition** (not a number): "monthly revenue by machine this year" → Claude tool-use returns `{ metric:'revenue', dimension:'machine', dateRange:'year', viz:'bar' }`, validated against the §3 registry (reject/repair invalid keys/pairs). The definition lands in the **builder, editable** — owner reviews before save/schedule. AI **never** runs the aggregation or invents values; `computeMetric` always produces the data deterministically. Reuses the existing encrypted-secret key storage and graceful-degradation rule.

---

## 8. Integration points (exact)

- `renderer/reporting.js` **(new)** — `computeMetric(metric, dimension, filters, range)` registry + `validPairs`; `renderReportPreview(def, el)`; `renderReportsTab()`; `renderDashboard(dashId, el)`. Calls existing `inRange`, `orderRevenueBase`, `orderOwedBase`, `computePartBaseCost`, `payStatus`, `convertToBase`, `clientCurrency`, `fmtPrice`, `fmtMoney`, `currencySymbol`, `escapeHtml`, `localName`.
- `renderer/analytics.js` — refactor per-record aggregation in `renderPnLSection`/`renderSLASection`/`renderClientLtvTable`/etc. into reusable compute fns the registry imports (keep render wrappers intact).
- `renderer/settings.js` — extend `renderDigestSettings()` (reportIds multi-select, format radio) and `buildDigestEmailHtml()` (report-rendering branch).
- `renderer/integrations.js` — `checkAndSendDigest()` unchanged except passing `attachments` when `format !== 'email'`.
- `renderer/app-state.js` — add `reports` + new `emailDigest` keys to defaults and the `nested` merge list.
- `main.js` `hub:send-email` + `lib/custom-smtp.js` — optional `attachments` / multipart MIME.
- `renderer/app-helpers.js` — reuse `csvEsc`, `downloadBlob`; `window.hubAPI.exportPDF` for PDF.

---

## 9. Edge cases

- **Empty data** — metric returns 0 / dimension yields no rows ⇒ preview and email show the existing "no data" empty state (`an.no_data`), never a crash or blank email.
- **Large ranges** — `'all'` over years of orders: aggregation is O(orders); cap dimension cardinality (e.g. top-N + "other") for `client`/`product`/`order` viz to avoid 1000-row tables; tables paginate, charts top-N.
- **Currency mix** — orders in client currencies are normalized via `orderRevenueBase`/`convertToBase` into `settings.currency` before grouping; a footnote notes the base currency. Missing exchange rate ⇒ amount passed through unchanged (existing behavior) — do not silently zero it.
- **VAT** — `vatCollected`/net measures derive VAT inclusive (`price * rate / (100+rate)`, gated by `settings.enableVat`, default `vatRate` 15); zero-rated orders (`vatRate===0`) excluded from VAT but counted in revenue, matching `renderPnLSection` and the GAZT return.
- **RTL / Arabic** — report titles, labels, money position respect locale (`localName`, `fmtPrice` ` ` placement, `dir`); PDF/email honor RTL.
- **Deleted entities** — a saved report referencing a deleted client/machine ⇒ filter yields empty, surfaced as empty state; orphan `reportId` in a schedule/dashboard is skipped, not fatal.
- **CSV injection** — all exported cells go through `csvFormulaNeutralize`/`csvEsc`.
- **Scheduler off-hours** — app closed at send hour ⇒ digest sends on next launch within the window (existing 10s-after-boot check), dedupe via `lastSentDate`.

---

## 10. Test plan & DoD

- **Compute parity** — `computeMetric('revenue','month',{},'year')` equals the totals `renderRevenueChart`/`renderPnLSection` produce for the same data (no drift between builder and Analytics).
- **Definition round-trip** — save → reload (`saveAll` + merge-on-load) → identical definition; orphan reportId tolerated.
- **Valid-pair gating** — invalid `(metric×dimension)` combos are not offered; AI/JSON returning an invalid pair is rejected/repaired, never rendered.
- **Filters & range** — client/status/paid/tag filters and custom `{from,to}` narrow results correctly; multi-currency sums match `orderRevenueBase`.
- **Empty/large** — empty data ⇒ empty state, no crash; large range ⇒ top-N cap applied.
- **Scheduled digest** — with `reportIds` set, `buildDigestEmailHtml` includes those reports; `checkAndSendDigest` still dedupes via `lastSentDate`; empty `reportIds` reproduces the legacy digest byte-for-byte.
- **Attachments** (if in scope) — PDF/CSV attach via extended `hub:send-email` across all three providers + custom SMTP; CSV is BOM + neutralized.
- **No-key AI** — NL builder hidden with no API key; manual builder fully functional; app unchanged.
- **VAT/RTL** — VAT-inclusive math matches existing P&L; Arabic locale renders RTL with correct money placement.

**DoD:** an owner can build, preview (from existing compute), save, and arrange reports into a dashboard; can attach saved reports to the recurring digest with chosen cadence/recipients/format; analytics is reused, not rebuilt; with no AI key the feature is fully usable manually; empty/large/multi-currency/VAT/RTL cases degrade gracefully with zero new mailer or analytics engine.
