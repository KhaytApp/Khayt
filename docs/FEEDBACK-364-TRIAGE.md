# Triage — David's feedback list (issue #364, 2026-08-10)

Ten suggestions from a real shop owner, gathered in
[KhaytApp/Khayt#364](https://github.com/KhaytApp/Khayt/issues/364) over two weeks
and consolidated into a numbered list on 2026-08-09. This document says, for each
one, what the code actually does today — every claim below was run in the app or
read in the source, never inferred from a feature name.

**Headline: four of the ten are already built, and he cannot see any of them.**
Everything he asked for that is done shipped to the **beta** channel in the last
six days; stable is still v3.5.3 from 2026-08-01. One of the four is not even
tagged yet. That is not a coincidence worth shrugging at — it is the whole
finding. The most valuable thing we can do for this user is not write code, it is
get 3.6 in front of him.

One genuine bug came out of it, and it is worse than he reported.

---

## Summary

| # | Ask | Verdict |
|---|---|---|
| 3 | POs for low stock should include consumables | **Done** — #654, in the untagged beta.16 |
| — | Consumable categories + a per-category view | **Done** — #650, beta.14 |
| — | Fees as a flat amount *or* a percentage | **Done** — beta.14, `lib/pricing.js` |
| 7 | Print a file directly from Khayt | **Done** — four printer protocols; a discoverability problem, not a gap |
| 6 | Cannot copy Shopify/Etsy links to sync orders | **Explained** — gated on cloud, and he was locked out of cloud until 2026-08-06 |
| 8 | Quote PDF prints English *and* Arabic | **Confirmed bug** — and worse than reported |
| 5 | Categories did not sync between two computers | **Not reproducible** — needs a question back to him |
| 1 | Sales-platform fee presets on the quote | **Real gap** — half the machinery exists |
| 2 | User-settable low-stock highlight colour | **Real gap** — small |
| 4 | Attach PDFs to a part, print and pack them | **Real gap** — order-level attachments exist, the rest does not |

---

## Already built

### Item 3 — consumables in the low-stock PO run

His words: *"When generating PO's for low stock items, I think it should include
consumables since running out of them could stop production just like running out
of filament."*

Shipped as #654. The changelog entry opens: *"Running out of glue, isopropyl, bags
or screws stops a job exactly the way running out of filament does."* The same
sentence, arrived at independently.

It is in **v3.6.0-beta.16, which is merged but deliberately untagged** — so it is
in no build anyone can install. Tagging it is a one-line action.

### Consumable categories (from his earlier email)

His words: *"having categories for consumables would be a nice feature… a drop
down to select just the item in that category."*

Shipped as #650 in **v3.6.0-beta.14, published 2026-08-09** — the same day he
wrote the list. `lib/consumable-categories.js`, a `category` field per item, a
picker above the list with counts, and uncategorised items kept as a group of
their own rather than vanishing behind a filter.

### Fees as a flat amount or a percentage (from his earlier email)

Shipped in beta.14. Each quote line carries its own unit picker — currency symbol
or `%` — resolved through `KhaytPricing.resolveExtraLines` so the breakdown cannot
disagree with the total printed above it (`renderer/build.js:775`). `lib/pricing.js:33`
already names the reason: *"That is what Etsy and Shopify actually charge against."*

### Item 7 — printing a file directly

Fully implemented in the main process. `hub:printer-send-gcode` sends an
already-sliced file; `hub:slice-and-print` slices first and then sends
(`main.js:922`–`990`). Four protocols: OctoPrint, Moonraker, PrusaLink, and Bambu
Lab (FTPS upload to the SD cache on :990, then start over MQTT).

**Why he could not find it.** It renders as a bare 🖨 emoji with no label, and
only when the machine has a printer API configured:

```js
${(m.printerApi && m.printerApi.type && m.printerApi.type !== 'none')
  ? `<button … data-act="slice-print" …>${_mIco('printer', '🖨')}</button>` : ''}
```
— `renderer/machines.js:71`

So a shop that has not set up a printer connection sees no button at all, and one
that has sees an unlabelled icon whose only affordance is a tooltip. Worth fixing
as discoverability, not as a feature.

---

## Explained

### Item 6 — copying the Shopify/Etsy links

*"I have not been able to copy shopify or Etsy links to sync orders."*

The buttons exist, but they are gated:

```js
if (sf.dir.includes('in')) actions.push(cloudReady
  ? linkBtn(importUrl(sf.id), 'Copy import link')
  : pill('connect cloud'));
```
— `renderer/settings.js:188`, where `cloudReady = cloud.enabled && cloud.url && cloud.shopId`

Without a cloud connection the button is replaced by an inert grey pill. Confirmed
in the running app: a fresh store has `cloud.enabled === false` and no `shopId`, so
every storefront row shows pills.

**David had no working cloud account until 2026-08-06** — our mail server was
sending from an address the provider had not authorised, so his verification code
never left the building. He almost certainly hit this during those weeks. Worth
one question to confirm rather than any code.

---

## The bug

### Item 8 — the quote prints in two languages

*"When generating a PDF quote it has both English and arabic. I would like to see
the quote generated in the chosen language."*

Confirmed, and it is by construction — `renderer/invoicing.js:1336` says so:

> The invoice is always bilingual, but the primary label (larger, bolder) matches
> the user's working language.

Every label is a pair, and both halves always render (`L` at `renderer/invoicing.js:1346`).
Driving the real app with an English UI, an English shop name and a US client, the
quote came out:

```
Riyadh, Saudi Arabia
الرياض، المملكة العربية السعودية

Quotation
عرض سعر
  No.     Q1001
  Date    Aug 10, 2026
  Hijri   1448/02/27

Bill to
الفاتورة إلى
```

**Two things are worse than he reported.**

1. **The second language is hardcoded Arabic**, not "the other language". Khayt
   ships nine locales. A French shop gets French + Arabic; a German shop gets
   German + Arabic. He happened to be the one who mentioned it.
2. **A Hijri date row prints on an English quote for a US customer.** He did not
   report this and may not have realised what it was.

**The constraint that makes this non-trivial.** ZATCA Phase 1 — Saudi e-invoicing —
requires Arabic on a tax invoice. So bilingual output must stay, and must stay
*forced*, whenever `settings.enableZatca` is on. The fix is a setting for everyone
else, not a deletion. The Hijri row should follow the same rule.

---

## Not reproducible

### Item 5 — "categories did not sync when syncing two different computer data"

At the time he wrote this there were **no user-defined categories anywhere in the
app**. `EXP_CATEGORIES` and `SUPPLIER_CATEGORIES` are frozen constants in source
(`renderer/expenses.js:6`, `renderer/inventory.js:2478`), and nothing
category-shaped appears in the 32 collections that sync
(`collectStoreCollections`, `renderer/app-state.js:427`). There was nothing that
*could* fail to sync.

Categories now exist, on consumables, as of #650. Checked whether the new ones are
sync-safe by running the real payload path in the app:

```
in snapshot      : [{"id":"CNS-1","category":"Hardware"}]
after normalize  : [{"id":"CNS-1","category":"Hardware"}]
```

The field survives both `buildStoreSnapshot()` and the
`KhaytStoreValidate.normalizeStoreSnapshot()` gate a peer applies on receipt, so
the feature he asked for is not carrying the bug he predicted.

**This one needs him, not us.** Ask which screen he meant.

---

## Real gaps

### Item 1 — sales-platform fee presets

*"Add a checkbox for the sales platform to the quote… Etsy for instance charges
two percentage based fees and a relisting fee of .20 for each item sold."*

He raised this twice, which makes it the thing he most wants.

**Half is done:** a quote line can already be a percentage or a flat amount, and
percentages resolve against the correct base — `lib/pricing.js` computes extras
against the pre-extras subtotal precisely because that is what marketplaces charge
against.

**Missing:** per-platform presets in settings (Etsy: two percentages plus a $0.20
flat; Shopify: its own), a picker on the quote, and applying them as lines
automatically. The storefront list to key them off already exists in
`lib/integrations-registry.js`, which knows Etsy, Shopify, WooCommerce, BigCommerce
and Wix per market.

### Item 2 — a colour for low-stock items

*"a color setting for Low stock items… where the color selection for the theme is."*

Low stock is already highlighted, but the colour is the theme's `var(--warning)`
(amber) and `var(--danger)` (red), used inline across roughly ten render sites in
`renderer/inventory.js`. Those two variables carry plenty of non-stock meaning
elsewhere, so this needs a dedicated `--low-stock` token rather than an override of
`--warning`. Small, and the settings surface he names already exists.

### Item 4 — attachments on a part

*"the ability to add other files to a part… (PDF for assembly instructions, or
safety sheets). These would be printed when the part is made and added to the
package when shipped."*

Attachments exist, but one level up and without the workflow: an **order** takes
files through `pickAndSaveOrderFile` with open and remove
(`renderer/order-flows.js:1829`). Three things are missing — attaching at part
level, printing the document alongside the job, and including it in the packing
step.

---

## What to do

1. **Tag v3.6.0-beta.16 and tell David.** Four of his ten asks are already
   written; he is running a stable build that has none of them. This costs one
   command and is worth more to him than anything below.
2. **Fix item 8.** The only confirmed bug, on a customer-facing document, affecting
   every non-Arabic shop — which is most of them.
3. **Ask him two questions:** which screen item 5 meant, and whether item 6 came
   right once his cloud sign-in started working on 2026-08-06.
4. **Then item 1**, as the feature he asked for twice and the one with half its
   machinery already in place.
