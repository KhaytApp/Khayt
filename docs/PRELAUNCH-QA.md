# Khayt 3.0 beta — pre-launch manual QA

Automated coverage (CI on every PR) already exercises: 692 desktop unit tests,
63 cloud contract tests, the 9-theme + RTL render shells, and an end-to-end
smoke (tabs, order lifecycle, store, LAN PIN gate). This checklist covers what
automation **can't** — paths that need real provider keys, a second device, or
hardware. Run it against a real `cloud.khaytapp.com` account before announcing.

Legend: ☐ to test · note the build version + OS for each pass.

## Automated RC hardening — done in beta.21 (2026-06-27)
Verified via headless Electron probes (demo + synthetic data); all ✅ unless noted:
- ✅ **Fresh-install first run**: onboarding wizard now shows for brand-new shops.
  (Fixed a bug where the default starter inventory made a fresh install look like
  an existing shop and skipped onboarding.) 0 runtime errors.
- ✅ **Scale**: 3,000 orders + 400 clients — every tab renders, 0 runtime errors;
  tab switches ~150–320 ms (inventory ~850 ms at that volume — acceptable, watch).
- ✅ **All 10 designs**: switch each + navigate dashboard/queue/logs/calculator/
  settings — 0 runtime errors per design.
- ✅ **All 8 locales** at full key parity; de/fr/es/ja/zh render with 0 runtime
  errors across tabs.
- ✅ **a11y**: 0 unlabeled form controls across all tabs (beta.20 pass).
- ✅ Full suite green: 692 desktop tests, 63 cloud contract tests, e2e smoke,
  9-theme + RTL shells.

## Cloud sync & accounts
- ☐ Sign up → set sync passphrase → save recovery key → data syncs.
- ☐ **Second device / reinstall**: log in, "Restore from cloud", unlock with the
  passphrase → data matches. Confirm the passphrase is never stored (re-prompt on
  relaunch).
- ☐ Password reset email → reset → log in with the new password.
- ☐ Email verification flow (if mailer configured).

## Team accounts (multi-user)
- ☐ Owner → 👥 Team → invite a member by email (real inbox) → code arrives.
- ☐ Member: "Join a team" with the code + own password + the shared sync
  passphrase → sees the same shop data on their device.
- ☐ Owner removes the member → removed account can no longer log in.
- ☐ Role badge reflected; non-owner doesn't see the Team button.

## Storefront + checkout + promos
- ☐ 🏬 Storefront: set prices, deposit %, pay link, add a promo code → Publish.
- ☐ Open the public `/shop/<id>` link on a phone → products + prices show; cart
  total + deposit compute; **Pay deposit** opens the pay link with the amount.
- ☐ Apply a promo: valid → discount; expired/maxed/invalid → correct message;
  total + deposit recompute.
- ☐ **Shipping + tax** (beta.15): add shipping methods + a tax % in the editor →
  on `/shop`, pick a shipping method and confirm the summary shows shipping, tax,
  and a grand total = net + shipping + tax (deposit + pay link follow the total).
- ☐ Submit the order → it lands in **Order requests** itemised (total, deposit,
  promo code, shipping, tax).
- ☐ Unpublish → the `/shop` link shows "no storefront".

## Order tracking
- ☐ Publish an order to the portal → open `/p/<token>` → stage timeline shows the
  current step (in the customer's language).
- ☐ Advance the order's status in the app → re-open the link → timeline updates.
- ☐ A quote link still shows approve/deposit (no timeline).

## Customer reviews
- ☐ Copy review link (🏬 Storefront → Copy review link) → open `/review/<id>` →
  submit a rating + comment.
- ☐ Storefront shows ★ avg (count); desktop Storefront panel shows the aggregate.
- ☐ Bad rating (0/6) rejected; review rate-limit holds (≤10/h per IP).

## SMS / WhatsApp (real provider key)
- ☐ Settings → SMS/WhatsApp → configure Twilio **or** WhatsApp Cloud **or**
  Unifonic **or** a webhook → Send test → message received.
- ☐ Clients → 📣 Campaign: pick a segment, compose with merge fields, preview,
  send to a small test segment → received; opted-out client skipped.

## Accounting sync (webhook)
- ☐ Settings → Accounting Sync → set a webhook URL (e.g. webhook.site) + secret →
  Send test → payload arrives with `X-Khayt-Secret` + `Idempotency-Key`.
- ☐ Mark an invoice paid → push fires once; re-saving doesn't double-push
  (idempotent via `accountingPushedAt`).

## Printers (hardware)
- ☐ **Bambu**: set IP + access code + serial → status shows (state/%/temps);
  🖨 Slice & print uploads over FTPS and starts the job.
- ☐ OctoPrint / Moonraker / PrusaLink (any on hand): status + send-to-print.

## Labels & QR
- ☐ Queue card 🏷 → order label prints; QR opens the tracking page.
- ☐ Inventory → 🏷 Labels → spool labels print; QR encodes the spool.

## Recurring orders
- ☐ Enable recurring on a client (with a completed order as template) → due cycle
  auto-creates an order; verify pause / stop-after / skip-next.

## Demand forecast & reorder
- ☐ Reorder suggestions: a material with open orders shows reduced "days left" +
  a "Committed" figure; "Draft purchase orders" creates draft POs.

## AI assistant
- ☐ ✨ Ask AI (with an Anthropic key) → ask a question, then a follow-up
  ("and last month?") → answer uses prior context; numbers match the data.

## Upgrade safety
- ☐ Install this build **over a previous version** that has real data → app
  loads; all data intact; a backup exists; cloud schema migrates without error.

## New in beta.15
- ☐ **Export all data (CSV)**: Settings → Data → Export all data (CSV) → pick a
  folder → a `khayt-export-<date>/` with one CSV per collection; opens cleanly in
  Excel/Sheets (no formula injection). Empty shop → "no data" message.
- ☐ **Remote mobile control**: on `/m` (login + unlock), Printers tab shows each
  machine with a live Printing-now/Idle badge; a quote shows Approve/Decline →
  approving moves it to pending on the desktop, declining voids it.
- ☐ **P&L summary CSV**: Analytics → P&L summary → exports an income statement for
  the selected date range (revenue, COGS, gross, opex by category, VAT, net).
- ☐ **AI price suggest**: calculator margin field → ✨ Suggest → shows median
  margin from comparable jobs (+ AI rationale when a key is set); Apply sets the
  margin. With no priced history → "not enough history".
- ☐ **Per-quote currency**: calculator Currency selector → set a non-base currency
  → invoice/quote renders in that currency; "Auto" keeps client/base behavior.
- ☐ **Offline auto-retry**: with cloud on, go offline → make an edit (status shows
  offline) → restore connectivity → change uploads automatically (no manual sync).

## New in beta.16–18
- ☐ **Storefront variants + checkout**: a product with options (Color/Size) →
  customer picks on `/shop`; shipping method + tax show; order arrives itemised.
- ☐ **Mobile triage + inventory**: `/m` Requests tab accept→quote / decline;
  Inventory tab deduct/top-up a spool → syncs to desktop.
- ☐ **Portal balance + invoice PDF**: published order shows Pay balance (amount
  filled in) + Download invoice (PDF) prints a clean invoice/receipt.
- ☐ **Executive summary**: Analytics → Executive summary → KPIs + on-time % + top
  lists; date-range + location switchers re-scope live.
- ☐ **Scheduling board**: Queue → Schedule → per-machine "ready by" + late flags.
- ☐ **Auto-draft POs / supplier prices**: enable Auto-draft POs → low items draft
  POs at the cheapest matching supplier price.
- ☐ **Subscriptions**: create a retainer → on the due date an invoice is generated;
  MRR shows. **Activity log**: status changes attributed to the operator.
- ☐ **Invoice template** (Classic/Modern/Minimal), **monthly digest**, **overdue
  payment flagging**, **guided tour**, **Turkish UI**, **keyboard focus + skip
  link**, **named restore points** (create → restore round-trips).

## Cross-cutting
- ☐ Arabic (RTL) spot-check of the new screens (storefront, review, campaign,
  P&L/CSV export, AI price modal, remote `/m`, executive summary, restore points).
- ☐ Run fully **offline** (no cloud) → core app works; cloud features degrade
  gracefully and auto-retry when back online.
- ☐ Crash reporting: confirm Sentry receives nothing during normal use (privacy)
  and an opt-out path exists.

## Road to 1.0 (release-candidate plan)
A checklist to promote the 3.0 beta line to a 1.0 stable release.
- ☐ **Feature freeze**: stop adding features for one cycle; only fixes + polish.
- ☐ **Full manual QA pass** of this document on a clean machine + an upgrade from
  the previous stable, on macOS, Windows, and Linux.
- ☑ **i18n**: all 8 locales (en/ar/tr/de/es/fr/ja/zh) at full key parity (beta.21);
  en⊆ar hard gate green. Spot-check each locale's nav/chrome renders without
  overflow in LTR + RTL on a real build.
- ☐ **Cut a release candidate** tag `v3.0.0-rc.1` → verify all three platform
  builds sign/notarize and the website surfaces it.
- ☐ **Soak the RC** for ~1 week with real shops; triage any regressions.
- ☐ **Docs/site**: changelog, feature list, screenshots, and pricing/licensing
  (FSL-1.1-Apache-2.0) reflect the shipped feature set.
- ☐ **Promote**: re-tag the soaked RC as `v3.0.0` (drop the `-rc`/`-beta`
  prerelease flag) and announce.
