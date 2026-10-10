# Khayt — competitive landscape and roadmap (July 2026)

**Status: mostly delivered.** Written 2026-07 as a proposal after reading 13
products Turki collected, plus PrintStash from the earlier review. Section 3 is
no longer a plan — **R1 through R6 shipped in `v3.6.0-beta.1`** on 2026-07-31.
R7 is the only item still open, and it is blocked on hardware, not on code.

Kept as written rather than rewritten into a changelog: the reasoning that
picked these six is worth more than the list, and §5 records what would have
made it wrong. Each item below now says what it became.

Companion to [KHAYT-3.0-ROADMAP.md](./KHAYT-3.0-ROADMAP.md), which remains the
platform north-star. That document answers *"where does Khayt run"*. This one
answers *"what does Khayt do that the field does not"*.

---

## 0. What was actually read

Facts below come from each product's own pages, read July 2026. Three could not
be read and are marked — they are **not** guessed at.

| Product | Category | Model | Read? |
|---|---|---|---|
| [FoxTrack](https://foxtrack.studio/) | **Shop management** — orders, inventory, invoicing, CRM, printer logs | Free / $9 / $29 per month | ✅ |
| [CalcMyPrint](https://calcmyprint.com/) | "3D Printing Business Management Platform" | unknown | ⚠️ JS-only; tagline is all that could be read |
| [Printago](https://printago.io/) | **Print-farm automation** — routing, cloud slicing, Shopify/Etsy | Freemium, unlimited printers | ✅ |
| [Quote3D](https://quote3d.com/) | **Instant-quote widget** for service bureaus | API + embed widget | ✅ |
| [3D Print Price Calculator](https://3dprintpricecalculator.com/) | File → price, very deep cost model | Free web tool | ✅ |
| [3D Price Lab](https://3dpricelab.pamelesxi.gr/) | File → price, 90+ printers, 80+ filaments, in-browser | Free alpha, Pro planned | ✅ |
| [MeshVault](https://www.meshvault.app/) | **Model library** + browser capture from Printables/Thingiverse | $19.99 one-time | ✅ |
| [Meshory](https://meshory.com/) | **Model library**, local-first, 40k models tested | $34.99 one-time | ✅ |
| [PrintStash](https://github.com/xiao-villamor/PrintStash) | Self-hosted asset manager + Moonraker | AGPL, self-host | ✅ |
| [MeshTune](https://meshtune.com/) | Mesh repair/analysis, WASM, nothing uploaded | Free | ✅ |
| [STLMaid](https://www.chapterfour.de/stlmaid/index.html) | Meshmixer replacement — cut, repair, connectors | Paid, 7-day trial | ✅ |
| [Obloid](https://obloid.app/tools/stl-splitter) | Browser tools — splitter, converters, AI generate | Freemium | ✅ |
| [Layova](https://layova.ca/) | unknown | unknown | ❌ 403 |
| RIGHTPrint | unknown | unknown | ❌ not findable |

### The field sorts into four buckets, and Khayt sits in only one

1. **Shop management** — FoxTrack, CalcMyPrint. *Khayt's actual competitors.*
2. **Pricing calculators** — 3DPPC, 3D Price Lab, Quote3D.
3. **Model libraries** — MeshVault, Meshory, PrintStash.
4. **Mesh tools** — MeshTune, STLMaid, Obloid.

Printago is its own thing: farm automation at 3–300 printers. Not Khayt's buyer.

---

## 1. The one finding that matters most

**Every pricing calculator in this list starts from a file. Khayt starts from
numbers the user must already know.**

Verified, not remembered: `lib/calculator-cost.js` takes `printWeight`,
`printTime`, `spoolCost` and `spoolWeight`, and hands a `baseCost` to
`pricing.quoteTotal`. The user supplies the two hardest numbers. 3D Price Lab,
3DPPC and Quote3D all take an STL/3MF/OBJ upload and derive weight and time
themselves — 3D Price Lab in-browser, against 90+ printer profiles and 80+
filaments.

So the insertion point is precise: produce `printWeight` and `printTime` from a
file, and the rest of the chain — cost, margin, tier, quote, order, invoice —
already exists and is already tested.

That is a real gap, and it is the *cheapest* one Khayt can close, because the
machinery is already in the repo and unrelated to it:

- `lib/mf-mesh.js` (402 lines) — parses 3MF into triangle arrays
- `lib/gcode-parse.js` — already reads slicer metadata
- `lib/mf-convert.js` (1,079 lines, 74 tests) — the converter
- `lib/pricing.js` — the cost engine, extracted this month, already pure

Nobody has to invent geometry code. The work is wiring what exists into the
quote, and being honest about the difference between a *sliced* estimate and a
*geometric* one.

**Khayt's unfair advantage here:** the calculators are anonymous one-shot web
tools. Khayt already knows this shop's filament prices, printers, electricity
rate, labour rate and margin — from `settings`. A file-derived estimate in Khayt
is priced with *the shop's own numbers*, and the resulting quote becomes an order,
an invoice and a ZATCA-compliant document. None of them can follow through.

---

## 2. Where Khayt is already ahead, and should stay

Worth naming, because a roadmap that only lists gaps distorts the picture.

- **Money that survives scrutiny** — ZATCA, credit notes netted out of revenue,
  voids and refunds subtracting properly. No calculator does invoicing at all;
  FoxTrack does PDFs, not tax compliance.
- **Nine languages, RTL-first.** The entire field above is English-only.
- **Local-first with opt-in E2E cloud** — Meshory and MeshVault are local-first
  but have no shop layer; FoxTrack and Printago are cloud-only.
- **Organisations** — one passphrase across branches, shipped this month. Nothing
  in this list does multi-branch.
- **A phone companion that works over LAN** with no account.

---

## 3. Roadmap

Ordered by *value per unit of risk*, not by size. Each item says what already
exists, so none of them starts from zero.

### Now — closes the clearest gap  ·  **both shipped**

**R1. File → estimate → quote.** — **shipped [#531], v3.6.0-beta.1**

Drop an STL/3MF/OBJ on the calculator; Khayt
derives volume and bounding box, applies the shop's own filament density, waste
and margin, and produces the quote it already produces.
*Exists:* `mf-mesh.js`, `pricing.js`, the whole settings model.
*Risk:* a geometric estimate is not a sliced estimate. It must be labelled as an
estimate and never presented as slicer truth — the same discipline as the
currency work: no number that looks more certain than it is.
*Wedge:* for 3MF from Orca/Bambu/Prusa, `gcode-parse.js` can read the slicer's
*actual* time and filament, which is exact. Do that first — it is strictly better
and less work than estimating.

**R2. Browse the Bed Ready library properly.** — **shipped [#530], v3.6.0-beta.1**

The panel today is a 560px modal
with a list and "download all" — no search, no filter, no preview, no thumbnails.
Meshory and MeshVault show what this should be.
*Exists:* the whole data path — `lib/makerrun-library.js`, seven IPC channels
including `bedreadyImportToLib(item, vaultId)`, cover fetching, SSRF-guarded
downloads. Only the browsing surface is missing.
*This is the highest ratio of value to new code in the entire document.*

### Next — differentiates rather than catches up  ·  **all three shipped**

**R3. Measured cost, not estimated cost.** — **shipped [#533], v3.6.0-beta.1**

PrintStash pulls *actual* grams and
duration from Moonraker on completion. Khayt logs waste and estimates cost, but
never learns what a job really cost. For a shop, estimate-versus-actual is the
margin question — and Khayt is the only product here that could put both numbers
on the same invoice.
*Exists:* printer polling, `wasteLog`, the full cost engine.

**R4. Settings that worked, remembered.** — **shipped [#534], v3.6.0-beta.1**

PrintStash keeps G-code revisions per
model with `known_good` / `needs_test` / `failed`, one recommended at a time.
Khayt has `printFiles` and reprints but no memory of *which settings succeeded*.
A shop reprinting a part six months later is guessing today.

**R5. Customer uploads a file and gets a price.** — **shipped [#532], v3.6.0-beta.1**

Quote3D's whole business.
Khayt already has `/api/intake` (a customer request form), `/api/quote`, a
storefront catalog and a portal — the pipeline exists, but a customer cannot
attach a model and see a number.
*Depends on R1.* Do not start before it.

### Later — worth doing, not worth rushing

**R6. Model library as a first-class surface.** — **shipped narrowly [#535], v3.6.0-beta.1**

~~Extend R2 beyond Bed Ready:
thumbnails, tags, collections, dedup by content hash, 3D preview.~~ Meshory
charges $34.99 for exactly this. It is a real product on its own — which is the
warning: it is also a *different* product, and Khayt's buyer is a shop, not a
hoarder.

*Done, narrowly, and here is what the list turned out to be worth:* four of the
five already shipped. `renderer/printfiles.js` had thumbnails (embedded and
rendered), tags with filtering, folders as collections, and a 3D preview. Only
**dedup by content hash** was missing — and it is the one item on that list that
serves a shop rather than a hoarder, because it is what connects a repeat
customer's file to the known-good setup (R4) and the measured cost (R3) already
recorded against it.

Built: `lib/model-identity.js`, hashing on import in the main process, an
import-time warning, and a card badge. Two kinds of match, kept apart on
purpose — identical bytes is a certainty, identical geometry is a hint and is
worded as one. Not built: the rest of the Meshory surface. That warning above
was right.

**R7. SDCP resin printers.** — **OPEN: hardware only**
Protocol layer built and tested ([#529]). The socket layer followed on
2026-08-24: a WebSocket client with the socket injected — so opening late,
answering out of order, answering for another machine, saying nothing, and
hanging up mid-handshake are all reachable from tests rather than only from a
printer — plus UDP discovery, the poll branch, and the connection type in the
machine dialog. Discovery matters more here than it looks: SDCP addresses a
printer by a mainboard id that is printed nowhere on the machine, so without a
scan a shop cannot configure one at all.

*Still the only item on this roadmap that is not done, and now blocked on
hardware alone.* What is unproven is exactly one step — whether a real mainboard
answers the `M99999` broadcast and accepts the request frame. The broadcast was
run against a live LAN with no Elegoo on it and behaved: bound, retransmitted
three times, timed out cleanly, found nothing.

[#529]: https://github.com/KhaytApp/Khayt/pull/529

### What shipped beyond the list

Two things came out of building R1–R6 that were not in this document:

- **The order → print-file link** ([#536]). Joins a finished job to the file and
  setup that produced it, so a measured cost (R3) and a known-good setup (R4)
  attach to the model (R6) rather than floating free. Without it the three are
  separate records that happen to be true at the same time.
- **The estimator's constants stopped being guesses** ([#537]). `density ×
  throughput` is grams per hour, which is directly measurable, so
  `estimate-calibration.js` learns it from finished jobs. The old default was
  optimistic by roughly 3× against real ones.

R1's stated wedge — read the slicer's *actual* figures from a 3MF before falling
back to geometry — turned out to expose two bugs that had never worked at all: a
3MF is a ZIP, so reading it as text found nothing, and Bambu/Orca print times
were parsed by a regex that never matched. Both are fixed.

[#530]: https://github.com/KhaytApp/Khayt/pull/530
[#531]: https://github.com/KhaytApp/Khayt/pull/531
[#532]: https://github.com/KhaytApp/Khayt/pull/532
[#533]: https://github.com/KhaytApp/Khayt/pull/533
[#534]: https://github.com/KhaytApp/Khayt/pull/534
[#535]: https://github.com/KhaytApp/Khayt/pull/535
[#536]: https://github.com/KhaytApp/Khayt/pull/536
[#537]: https://github.com/KhaytApp/Khayt/pull/537

### Deliberately not doing

- **Print-farm automation** (Printago). Different buyer, enormous surface.
- **Mesh repair / splitting** (MeshTune, STLMaid, Obloid). Real craft, adjacent
  business, and MeshTune gives it away free. Link out; do not build.
- **AI model generation** (Obloid). Not a shop-management problem.
- **Self-hosting, RBAC, S3, Postgres** (PrintStash). Khayt is a desktop app with
  an opt-in encrypted cloud. That was a decision, not an omission.

---

## 4. On pricing

FoxTrack is the only directly comparable product with public numbers:
**free / $9 / $29 per month.** The library tools are one-time: $19.99 and $34.99.
The calculators are free.

Two products found on 2026-07-31, after the above was written, move that anchor:
**Layers is free** for what it calls full access to core features — and what it
covers is the file→quote→order pipeline, i.e. R1 and R5. **3DPBOSS is one-time
$49/$99/$139.** So the file-to-quote pipeline is something a shop can already get
for nothing, while nobody found so far charges for — or offers — estimate versus
measured actual.

That is a data point about the *field's* anchor, not a recommendation. Khayt does
ZATCA invoicing and nine languages; comparing it to a $9 order tracker on price
alone would undersell it. Positioning is Turki's call — this document only
records what the field charges.

---

## 5. What would make this roadmap wrong

Stated so it can be checked rather than assumed:

- **If shops do not actually want file-based quoting**, R1 and R5 collapse. The
  evidence is that five products in this list are built on it — that is strong,
  but it is evidence about *the market for calculators*, not proof about Khayt's
  existing users. Worth asking a real shop before building R5.
- **If Bed Ready's library is small in practice**, R2's payoff shrinks to a nicer
  modal. Worth checking real library sizes first — one query.
- ~~**Layova and RIGHTPrint are unread.** Either could invalidate a section here.~~
  **Checked 2026-07-31 — and the list itself was the problem.** Neither can be
  read: `layova.ca` returns 403 to any fetch and has no search presence, and
  nothing surfaces under "RIGHTPrint" at all. Two of the thirteen entries are
  therefore unverifiable, which is worth knowing about a list that was used to
  justify a quarter of work.

  Searching for them turned up two directly comparable products that were **not
  in the review**, which is the more useful finding:

  - **[Layers](https://layers.app/)** — customer uploads a model and gets an
    automatic price, plus invoicing, inventory, CRM and multi-currency. That is
    R1 and R5 as a whole product, and it has a **free tier billed as full access
    to core features**. The closest thing to Khayt found so far.
  - **[3DPBOSS](https://3dpboss.com/)** — CRM, production scheduling, inventory
    and margin analytics, one-time $49/$99/$139, built on Notion. No customer
    upload. States plainly that it "does not connect to printers directly".

  **The central claim survives contact with both.** Neither reads actual
  filament or duration from a printer, and neither reports estimate versus
  actual — 3DPBOSS requires that data to be typed in by hand. So R3, and the
  order→file link that makes it answerable per setup, remain the differentiator
  the document said they were. What changes is the pricing read: Layers gives
  away the file-to-quote pipeline, so R1 and R5 are table stakes to *have*, not
  something to charge for.

  *Caveat on all of the above:* these are vendor marketing pages read once, not
  hands-on evaluations. They are enough to place a product, not to trust a
  feature matrix.

---

## 6. Second reading — September 2026

Twenty products Turki collected on 2026-09-12, mostly print-farm tools rather
than the calculators and libraries of §0. Four were read properly; the rest
repeat their categories. **Every claim about Khayt below was checked against the
code, not assumed** — two apparent gaps turned out not to be.

| Product | Category | Model | Read? |
|---|---|---|---|
| [SimplyPrint](https://simplyprint.io/print-farms) | **Fleet automation** — 130+ brands, AI failure detection, usage-based maintenance | SaaS, LAN-only mode available | ✅ |
| [Printago](https://printago.io) | **Farm automation + commerce** — Shopify/Etsy → queue, "Gutenbed" routing, cloud slicing | Freemium, unlimited printers | ✅ (also §0) |
| [Stimalo](https://stimalo.com) | **Shop management** — costing, quoting, orders, FIFO batches | Free / €5.99 mo | ✅ |
| [3D Filament Profiles](https://3dfilamentprofiles.com/) | **Community filament database** — ~24k filaments, 900+ providers | Free, community-edited | ✅ |
| OctoFarm, Repetier-Server, Prusa Connect, 3DPrinterOS, OctoPrint | Fleet control, one of them vendor-locked | mixed | category only |
| Printventory, 3dprintmanager.eu, PrintFarmManager, 3DQue, BuildBee, Printandgo, 3diwell, LutraCAD | Farm / inventory management | mixed | category only |

### The field splits, and the split is the finding

**Fleet-automation-first** (SimplyPrint, Printago, OctoFarm, Repetier,
3DPrinterOS): bulk start, smart routing, cloud slicing, lights-out production,
failure detection. SimplyPrint's and Printago's own pages mention **costing,
invoicing and tax nowhere at all**.

**Books-first** (Stimalo, FoxTrack, Layers from §5, Khayt): what a job cost,
what it earned, who owes what.

Khayt is in the second bucket and should stay there. The first bucket will
out-automate it indefinitely — SimplyPrint claims 130+ printer brands against
Khayt's seven protocols — and competing there is a race Khayt loses while
neglecting the ground it holds.

### Stimalo is the closest competitor yet found

Closer than Layers. Materials, energy, **depreciation**, labour and packaging in
the cost model; four pricing strategies; quote-to-delivery tracking; FIFO
material batches at purchase price; G-code/3MF import auto-filling weight and
time. €5.99/month, with a free tier billed as having no hidden limits.

### Three false alarms, and one difference worth acting on

- **NOT a gap — machine depreciation.** *First written here as a confirmed gap;
  it was not one, and the error is left visible because the way it was made is
  instructive.* `lib/calculator-cost.js` line 52 is
  `wearCost = printTime * part.wearRate` — an hourly machine-wear rate, which is
  depreciation. It defaults to 0.75/hour in `lib/print-rates.js`, is overridden
  per machine, and the Mac app already carries it. The grep that "confirmed" the
  gap looked for `depreciation|amorti|machineWear|machineCost` and the code says
  `wearRate`. **A search that finds nothing has not proved absence — it has
  proved the vocabulary did not match.**
- **A real but much smaller difference.** Khayt asks the shop for the hourly
  figure; a shop that does not know what its printer costs per hour types
  something. Deriving it — purchase price, expected life in hours, salvage —
  would be a better question to ask. That is a usability improvement, not a
  correctness gap, and it is R8 below.
- **NOT a gap — FIFO material batches.** Khayt costs material per spool at that
  spool's own purchase price (`cost / weight * 1000`, see
  `lib/material-cost.js`). Each spool *is* its batch, which is more precise than
  pooling, not less.
- **NOT a gap — e-commerce.** `lib/integrations-registry.js` already carries
  Shopify, Etsy, WooCommerce, Salla, Zid and Medusa.

### The one genuinely new idea

**A community filament database.** ~24,000 filaments from 900+ providers, with
nozzle and plate temperatures, pressure-advance K-values and **HueForge
transmission distances**. Two separate uses: adding a spool becomes a lookup
rather than typing, and the TD data feeds the HueForge work directly. Nothing
else read this round was an idea Khayt did not already have.

### What none of them touch

ZATCA Phase 1 and 2, VAT, Arabic and RTL throughout, Salla and Zid, SAR. §2 said
this and it still holds — but it is worth restating that this is not a feature
list, it is a category the entire field above would have to enter deliberately.
Everything in this section is worth learning from; none of it is worth chasing
at the expense of that.

### Roadmap from this reading

**R8 — derive the wear rate instead of asking for it.** Khayt already costs
machine wear per print hour and has since long before this reading. What it asks
for is the hourly figure itself, which a shop has to work out. Asking instead
for purchase price, expected life and salvage — and computing the rate — is the
same arithmetic moved to the side that has the numbers. Small, and not urgent:
nothing is currently wrong.

**R9 — filament lookup instead of filament typing.** Populate a spool from the
community database. Wants a decision first on whether Khayt queries it live,
ships a snapshot, or contributes back.

**R10 — decide the automation line, in writing.** Khayt now finds printers,
controls them and proposes dispatch. It is not going to do cloud slicing or
lights-out production. Saying where the line falls stops it being redecided one
feature at a time.

*Caveat, as §5: vendor marketing pages read once, not hands-on evaluations.
Enough to place a product, not to trust a feature matrix.*

## 7. Third reading — October 2026

On 2026-10-10 every product in §0 and §6 was read again, and the field was searched for
anything new since September. The method is unchanged:

- facts come only from each product's own pages;
- anything that could not be read is marked as unread;
- every claim about Khayt was checked against the code in `lib/`, `renderer/`,
  `mac/KhaytCore/Sources` and `ios/`.

**Ten** apparent gaps turned out not to be gaps. One of them nearly got through for the
same reason §6's did. The verifying grep ran under zsh, which does not word-split
`$S`, so every search for a "missing" feature came back empty. That included searches
for features that exist, such as `wearRate`. A search that finds nothing has still not
proved absence. This time the shell, not the vocabulary, was why it found nothing.

### What changed among products already on the list

| Product | Change since July / September | Read? |
|---|---|---|
| [FoxTrack](https://foxtrack.studio/pricing) | **Prices rose about 33%.** Pro went from $9 to **$12/mo**, and Farm from $29 to **$39/mo**. The site now lists tax label and number on invoices ("GST, VAT or sales tax"), any currency, a **bring-your-own-key AI assistant**, and an open-source printer bridge. Its [roadmap](https://foxtrack.studio/roadmap) shows as done: multi-language invoices, Spoolman, API, emailing invoices, and Shopify/Etsy/Woo (in beta). Under consideration: RFID/NFC filament tracking. Mobile is a PWA only. | ✅ |
| [CalcMyPrint](https://www.calcmyprint.com/) | **Read for the first time** (§0 had only its tagline), from its JS bundle. It is a costing and catalogue tool: depreciation, wattage, failure rate, a labour library, a "recipe builder", G-code import, and stock by weight. **No invoicing, tax, portal, app or languages.** Price is €0 / €4.99 / €9.99 per month, still in beta. | ⚠️ JS bundle, not the rendered page |
| [Layers](https://layers.app/plans) | Paid prices are now confirmed: **$49 and $149 per month**, and the free tier allows 5 orders a month. Its UI has 11 languages, **including Arabic and Farsi**. [v1.13.1](https://layers.app/blog/layers-v1-13-1-release-note-more-control-better-workflows-easier-integrations) added an OpenAPI with orders and customers, Excel export, RFQs for CNC and moulding, and shareable part and order URLs. | ✅ (/pricing renders only in JS; /plans was read) |
| [3DPBOSS](https://3dpboss.com/) | No visible change. /pricing returns 404, and prices are still on the home page. | ✅ |
| [Printago](https://printago.io/changelog) | Shipping almost every week. Since September it has added Farm Reports including **Profit**, plus eBay, WooCommerce, **ShipStation** (Walmart/Amazon/BigCommerce), TikTok Shop, Wix and OneDrive. It also offers [**AI Agents**](https://printago.io/features/ai-agents): a CLI plus a **Claude Code skill**. Its [roadmap](https://printago.io/roadmap) lists **Part Estimation** ("so you can quote") as Up Next and a **Quote Portal** as Exploring. It still has nothing on invoicing or tax. | ✅ (docs.printago.io is an empty shell) |
| [SimplyPrint](https://simplyprint.io/blog/simplyprint-client-flashforge-dremel-prusa-klipper/) | **"The Shop"** is a closed pilot. An order comes in, becomes work in the queue, and goes on to packing. The wider release was due "in the next couple of weeks" from 23/09. It also has 15 UI languages, **none of them Arabic**. Still no costing, invoicing or tax. | ⚠️ changelog returned 403 |
| [Stimalo](https://stimalo.com/pricing) | v2.0.0, made by one person in Italy. It is **free for everyone until 31 Dec 2026**. It now has a [find-a-maker marketplace](https://stimalo.com/trova-maker) in Italy (230 makers), and its Italian page lists **AI that scans supplier invoices**. It still issues **no customer invoices**, and it is in IT/EN only. | ✅ (it has no public changelog) |
| [3D Filament Profiles](https://3dfilamentprofiles.com/) | It has grown from about 24k to **34,506 filaments**, with 5,460 TD values. | ✅ through a browser (direct fetches got 429) |
| [3D Print Manager](https://3dprintmanager.eu/) | **Read for the first time** (§6 listed it as category only). Of everything on the list, it is the **closest books-first match**. A LAN agent records actual usage from Bambu AMS, Prusa and Klipper. It costs each print with the real spool price and electricity, turns webshop orders into work orders, reserves filament, and issues **quotes and invoices through Minimax**, or a PDF with an EU payment QR code. Price is €0 / €3.99 / €19.99 / €39.99 per month. It is in HR/EN/DE, on web, Windows and Android. | ✅ |
| [MeshVault](https://www.meshvault.app/) | **It is now free** (it was $19.99), and an Android app and an iOS TestFlight build have appeared. | ✅ |
| [Meshory](https://meshory.com/) | The price goes from $34.99 to **$39.99 on 28 Oct**. It added "AI-powered visual search". | ✅ |
| [PrintStash](https://github.com/xiao-villamor/PrintStash) | v0.13.0. Support for Bambu LAN, PrusaLink, OctoPrint and Elegoo is now in beta. | ✅ |
| [Layova](https://layova.ca/) | **No longer 403** (it was in July). It is a production scheduler: import a 3MF, plan across printers by due date, and warn when a deadline is at risk. No public price. | ⚠️ JS bundle only |
| [Bambu Farm Manager](https://wiki.bambulab.com/en/software/bambu-farm-release-notes/3-0-0) | v3.0.0 adds "Start All" auto-matching by filament and colour, printer groups, and RTSPS video. **No cost, order or customer features.** | ⚠️ wiki read; bambulab.com returned 403 |
| [Print Farm Manager](https://printfarmmanager.com/) | $29 one-time and local. It reports profit per hour and "blocked revenue" from filament risk. No invoicing. | ✅ |
| Quote3D, 3D Price Lab, MeshTune, STLMaid, Obloid, OctoPrint, Repetier, 3DQue | No change that matters to Khayt. Quote3D now has API v2; OctoPrint 2.0 is at rc6. | ✅ |
| [OctoFarm](https://github.com/OctoFarm/OctoFarm) | **Dead.** The last release was in 2022, and octofarm.net now redirects to ad domains. | ✅ |
| Prusa Connect, 3DPrinterOS | Prusa Connect now advertises a "farm mode". Neither has cost, order or invoice features. Prusa's paid tiers could not be read: that pricing page renders only in JS. | ⚠️ partial |
| BuildBee, Print&Go, 3DiWell Farm Manager, Bambu Handy | — | ❌ JS-only, login wall or 403 |
| RIGHTPrint | Still nothing anywhere under that name. | ❌ not findable |

### New since September

| Product | Category | Model | Read? |
|---|---|---|---|
| [PrintMate](https://apps.apple.com/us/app/3d-print-cost-sales-printmate/id6743996044) ([site](https://foggyapps.com/printmate/)) | **Native Apple shop app.** Runs on iPhone, iPad, **Mac** and visionOS, with **25 languages including Arabic** and a **VAT % field**. Its 2026.08.01 release replaced Sales with Orders, quotes, invoices and delivery tracking. 2026.09.01 added **Bambu Lab integration that pre-fills jobs from printer history**, multiple printers, and monthly expenses. | Freemium (5 of each). Subscriptions from $0.99/wk up to about $39.99 lifetime | ✅ App Store page |
| [Printforge CRM](https://crm.printforge.com.au) | **Books-first, web.** STL/G-code cost breakdown, numbered PDF quotes, a **"Claude-powered" AI quote assistant**, a kanban, a Gantt calendar, and **GST/ABN tax invoices** with Stripe. Shareable customer upload links that can be revoked. Timesheets, shipments, Xero, Shopify, Etsy and Home Assistant. Built-in design generators (cookie cutter, stamp, mould). English only. | AUD 0 / 4 / 9 / 18 / 39 per month | ✅ |
| [CalcuMake](https://github.com/cmbaldwin/calcumake) | Books-first, open source (MIT, Rails). Pricing calculator, jobs, invoicing, clients and filament stock. 7 languages **including Arabic**. No tax calculation. | Free, or ¥150 / ¥1,500 per month | ⚠️ README and [Product Hunt](https://www.producthunt.com/products/calcumake); calcumake.com did not load |
| [FilaOps](https://github.com/Blb3D/filaops) | **Self-hosted "Print Farm ERP"** under BSL 1.1. Quotes, sales orders, invoices, payment terms and credit limits, multi-level BOM, MRP and purchasing, **double-entry GL and trial balance**, RBAC and 432 endpoints. | Free self-host; a "PRO" edition has been announced | ✅ |
| [MakerQuote.IO](https://makerquote.digico.com.mt/features) | Quote to invoice in one click, **"VAT-ready" invoices**, stock that deducts itself, shareable quote links, and **AI pricing "based on market rates"**. | Free, or €7.99/mo | ✅ |
| [3DPCC](https://3dpcc.com) | Costing, inventory, catalogue with SKUs, orders, stock reservation, quotes. Web plus an iOS app. No tax. | Free, or $12.50/mo | ✅ |
| [PrintPulse](https://print-pulse.app), [Prinate](https://prinate.app) | Quote, BOM and margin tools. Prinate also has quotes and invoices. Web only, no tax. | €0–19/mo; $0–5.99/mo | ✅ |
| [3dPrintOps](https://apps.apple.com/us/app/3dprintops/id6793183174), [3D Print Cost](https://apps.apple.com/app/id6758351451), [Spool cost calculator](https://apps.apple.com/us/app/spool-3d-print-cost-calculator/id6758672926) | Native Apple cost apps. 3dPrintOps runs on iPhone, iPad, Mac, **Watch** and Vision. The Spool app **imports history and spools from Bambu's cloud** and calculates drying cost and equipment ROI. | $1.99–$9.99, or a subscription | ✅ App Store pages (two of the release dates look wrong) |
| [Daedalus](https://pkg.go.dev/github.com/philjestin/daedalus) | Open-source desktop app (Wails). Orders from Etsy and Squarespace, printer control, **expense receipt OCR**, and profit per hour. No invoicing. | MIT | ✅ |
| [Bambuddy](https://github.com/Person2099/bambuddy), PrintOps | Self-hosted Bambu control. PrintOps is a fork of Bambuddy with costing and quotes. | AGPL | ⚠️ Bambuddy read through a third-party article |
| Spool: Filament Tracker, SpoolPainter, FilaMan | Spool trackers with Bambu auto-logging or NFC. | — | ⚠️ store listings only |

**No 3D-print shop software aimed at Arabic speakers or at Saudi Arabia was found.** The
only ZATCA-compliant tools that turned up are general accounting packages: Zoho Books,
Qoyod and Wafeq. Reddit threads from 2026 could not be reached through search.

**Meshmill: no 3D-printing product by that name exists.** These were checked:

- [jes/meshmill](https://github.com/jes/meshmill) is CNC CAM software from 2022.
- [make-your-own-world/MeshMill](https://github.com/make-your-own-world/MeshMill) is a
  GPL Windows tool for reducing scan meshes on a CUDA GPU. Its repo was **created on
  2026-10-04**, which makes it the likeliest thing the user saw. It prepares meshes "for
  downstream manufacturing tools", so it sits in the mesh-tools bucket, not with
  shop software.
- meshmill.com is a 2024 GoDaddy page about metaverse content, and meshmill.xyz
  redirects to it.
- meshmill .io, .app, .ai, .co, .net and .dev have no DNS record.
- The App Store has no app by that name in either spelling.
- GitHub search finds 6 repos with that name. None of them is about printing.

### The finding: Arabic stopped being unique, and ZATCA did not

§2 and §6 both counted Arabic and RTL as ground nobody else held. That is no longer true:

- **Layers** has Arabic in its UI.
- **PrintMate** has Arabic, on the Mac and the iPhone, with a VAT field.
- **CalcuMake** has Arabic in its UI.

What is still unique is **tax-compliant invoicing**: ZATCA Phase 1 and 2, VAT net of
revenue, and credit notes. FoxTrack prints a tax label, MakerQuote calls itself
"VAT-ready", Printforge issues GST tax invoices, and 3D Print Manager hands invoicing to
Minimax. None of them does Saudi e-invoicing. A **native Mac app** is no longer unique
either: PrintMate, 3dPrintOps and 3D Print Cost all run on the Mac. Khayt's distinct
combination is now **native Apple app + local-first + ZATCA + printer actuals**. The
copy on the website should lead with that. "We speak Arabic" is now one feature among
several.

The other movement is that **the automation bucket is moving towards books**, as §6
predicted. Printago now has a Profit report, and Part Estimation and a Quote Portal are
on its roadmap. SimplyPrint is building an order-to-queue Shop. Neither has invoicing or
tax yet, and both would have to choose to build it.

### Ten false alarms

Each item below looked like a gap on a competitor's page, and the code shows Khayt
already has it.

| Looked missing | Competitor | Where it is in Khayt |
|---|---|---|
| RFID/NFC spool tags | FoxTrack (under consideration), FilaMan | `ios/KhaytCompanion/NFC/NFCReader.swift` and `NFCEncoder.swift`, `WriteNFCTagSheet.swift`; on the desktop, a hex-dump import in `renderer/inventory.js` |
| AI with your own key | FoxTrack, Printforge | `lib/ai-providers.js` supports Anthropic, OpenAI, Gemini and Ollama. `lib/ai-tools.js` has `quote_extract`, `suggest_price`, `draft_customer_message` and `answer_shop_question` |
| AI pricing | MakerQuote ("market rates") | `lib/ai-price.js` suggests prices from the shop's **own** completed jobs, which is a better basis than "market rates" |
| Multi-language invoices | FoxTrack | `lib/invoice-language.js` |
| Reserving filament for orders | 3D Print Manager, 3DPCC | `committedByItem` in `lib/reorder.js`, and the reserved grams in `renderer/inventory.js` |
| Credit limits | FilaOps | `creditLimit` in `renderer/clients.js`, plus `lib/payment-plan.js` |
| Profit and failure reports | Printago Farm Reports | `lib/pnl-report.js`, `machine-pl.js`, `failed-print-cost.js`, `failure-rate.js` |
| Part Estimation and a Quote Portal | Printago (roadmap) | Shipped in July as R1 and R5 (`lib/public-quote.js`, plus Cloud `mobile/intake.html` and `portal.html`) |
| Recipe/BOM products and platform fees | CalcMyPrint, 3DPPC | `lib/assembly.js`, `print-kits.js`, components in the job margin (#1752), and `lib/platform-fees.js`, which includes eBay |
| Xero/QuickBooks and Home Assistant | Printforge, 3D Print Manager | `lib/accounting-export.js` covers QuickBooks, Xero and Zoho **as file exports, not a live sync**. `lib/smart-plug.js` talks to Home Assistant |

R8 (derived wear rate, `lib/depreciation.js`, #1659) and R9 (the filament catalogue,
`lib/filament-catalog.js`, #1194 and #1747) both shipped after §6 was written. R10, the
written automation line, is **still unwritten**. No document in `docs/` states it.

### Real gaps, verified

- **Bambu jobs have no actual figures.** In `lib/printer-actuals.js`, the `bambu`
  branch says "nothing is claimed here — the shop types these". PrintMate (pre-fill from
  printer history), the Spool app (Bambu cloud import) and 3D Print Manager (AMS usage)
  all fill them in. This is the one place where R3's differentiator does not reach the
  most common printer brand.
- **Scanning a supplier receipt.** Stimalo (AI invoice scanning) and Daedalus (receipt
  OCR) both read supplier documents. In Khayt, `lib/expense-book.js` stores a
  `receiptPath` and the receipt's VAT, but someone has to type it. iOS OCR exists only
  for filament labels (`LabelPhotoOCR.swift`, `FilamentLabelParser.swift`).
  `lib/zatca-qr.js` can *build* the TLV QR code but cannot *read* one.
- **An agent interface to the books.** Printago ships a CLI and a Claude Code skill.
  `KhaytMcp` exists (`mac/KhaytCore/Sources/KhaytMcp/`), but its tools cover only the
  **library**: `search_models`, `get_model` and `library_summary`. There are no tools
  for orders, receivables, stock or the P&L.
- **No Saudi accounting export targets.** `accounting-export.js` exports to generic,
  QuickBooks, Xero and Zoho formats. It has nothing for Qoyod, Wafeq or Daftra. Their
  import formats were **not read** this round.
- Smaller items, all real and all low value: an Apple Watch app (3dPrintOps), a count
  of every consumable in one pass (FilaOps), a double-entry ledger (FilaOps), design
  generators (Printforge), and a customer marketplace (Stimalo, Printforge).

### Ranked ideas

The buyer is a small Saudi shop with 2 printers, working in Arabic and English.

1. **Scan the ZATCA QR on a supplier's receipt to file the expense.** Every Saudi
   simplified tax invoice carries a TLV QR code with five fields: tag 1 seller, tag 2
   VAT number, tag 3 timestamp, tag 4 total, and tag 5 VAT. That makes it an exact read,
   with no OCR or AI guesswork, of the one figure a VAT-registered shop has to claim
   back as input tax.
   - *Why:* competitors use AI scanning to get this approximately. Khayt can get it
     exactly, and only in the one market where nobody else is looking.
   - *Exists:* the encoder in `lib/zatca-qr.js`, the barcode scanner on iOS
     (`BarcodeScannerView.swift`), and the expense book's receipt-VAT field.
   - *Effort:* small to medium. A pure `decodeTLV` in lib, plus a scan button on
     iOS and Mac.
   - *Lanes:* lib, then iOS first, then Mac.
2. **Real figures for Bambu jobs.** Take the per-plate sliced grams from the 3MF the
   printer actually ran. When Khayt itself sent the job, it already holds that file
   locally, because `lib/bambu-ftp.js` uploads it. For a job started elsewhere, the
   FTPS client would need a RETR added: today it can only STOR. Take duration from the
   MQTT start and finish timestamps rather than from remaining ÷ percent.
   - The result must be labelled "sliced figure for the plate printed", not
     "measured". That is the same discipline as R1.
   - *Why:* it is the most common printer brand in the market, and three competitors
     fill these figures already.
   - *Effort:* medium. *Lanes:* lib, then Mac, then Electron.
   - **Blocked on hardware:** the only printer on the bench is the U1, so this cannot be
     verified without a Bambu.
3. **Books tools in `KhaytMcp`, read-only.** Add tools for open orders, receivables and
   overdue payments, stock runway, a P&L for a period, and a quote draft.
   - *Why:* Printago and Printforge show that "ask an agent about my shop" is now
     something products ship. Khayt already has the server and the pure lib rules.
   - *Keep it read-only* so the store's write chain is never bypassed.
   - *Effort:* small to medium. *Lane:* Mac.
4. **Reposition on the website.** Change the copy from "Arabic" to "**ZATCA invoicing +
   native Mac/iPhone + local-first + measured cost**". Add a row comparing Khayt with
   FoxTrack's new $12/$39 prices and PrintMate.
   - *Why:* the Arabic claim can now be matched by three products; the ZATCA claim
     cannot.
   - *Effort:* tiny. *Lane:* the khaytapp.com website.
5. **Export formats for Qoyod, Wafeq and Daftra** in `accounting-export.js`. This is
   only worth doing after their import formats have been read. A Saudi shop's
   accountant is more likely to use one of these than Xero.
   - *Effort:* small, once the formats have been read. *Lanes:* lib, then both apps.
6. **Write R10.** SimplyPrint's Shop and Printago's Quote Portal are both moving into
   orders. The line Khayt will not cross (cloud slicing, lights-out production,
   marketplace connectors) should be on paper before the next feature argues it again.

### Deliberately not doing

- **A connector for every marketplace** (ShipStation, TikTok Shop, eBay, Walmart, as in
  Printago). A Saudi shop sells on Salla, Zid and WhatsApp, and Khayt already has those.
  Racing Printago's weekly connector releases means losing.
- **A maker marketplace** (Stimalo's find-a-maker, Printforge). It is a different
  business, two-sided, and needs liquidity Khayt does not have.
- **Design generators** (Printforge's cookie cutter, stamp and mould tools). Mesh tools,
  as in §3: link out rather than build.
- **A double-entry ledger** (FilaOps). Khayt exports to the shop's accountant; becoming
  the accountant's software is a different product.
- **Watch and visionOS apps** (3dPrintOps, PrintMate). Live Activities and Control Center
  already put a print on the wrist and the lock screen.
- **AI "market rate" pricing** (MakerQuote). A price taken from strangers' rates is a
  number the shop never agreed to. `ai-price.js` prices from the shop's own history on
  purpose.

### On pricing, briefly

The field's anchor moved upward:

- FoxTrack: $12 / $39.
- Layers: $49 / $149.
- 3D Print Manager: €3.99–€39.99.
- Printforge: AUD 4–39.

At the free end, MeshVault went free and Stimalo is free until the end of 2026. Native
Apple apps sell one-time for $2–$40. The pattern from §4 holds: plain order tracking is
cheap or free, and nobody charges for tax compliance because nobody else offers it.

*Caveat, as §5 and §6: these are vendor marketing pages read once, not hands-on
evaluations. They are enough to place a product, not to trust a feature matrix. The
App Store figures came through a summarising fetch.*
