# Nozzle wear — the figures, and where they came from

The machine card warns when a nozzle is due for replacement. This is the table
behind that warning, the reading it came from, and which parts of it are still
guesses.

**Checked 2026-08-30.** The numbers live in
[`lib/nozzle-wear-data.js`](../lib/nozzle-wear-data.js); this file is the longer
version with the conditions attached. Every figure is a **default a shop can
overwrite** — Settings → Printers → *Nozzle wear reference*.

## Why this file exists

The first version of the wear model shipped with a table of invented numbers.
They were plausible, they were labelled "rules of thumb" in the code, and they
had been checked against nothing. Two were wrong in a direction that mattered:

| | invented | measured |
|---|---|---|
| Glow-in-the-dark | 10× — the worst there is | **3×** — no measurable orifice change after 330 g |
| Brass life | 2,000 g | **5,000 g** — PETG widens a bore at 3–5 kg, PLA reports reach ~15 kg |

Glow was rated *above* carbon fibre on nothing but intuition. The 2,000 g brass
default would have told a shop printing ordinary PLA to bin a good nozzle
repeatedly.

## The sources disagree, and that is not a mistake

E3D found significant, microscope-visible degradation of a brass nozzle after
**250 g** of carbon-filled PETG. Other sources put brass at **1–2 kg** of the
same class of filament. Both are true. They are answering different questions:

- *When is this measurably worn?* — a microscope and a bore gauge
- *When do prints stop being acceptable?* — a shop looking at a part

For a shop selling parts those are months apart, which is why the defaults sit
between them and why the override is a first-class feature rather than a
nicety. Nothing in this table knows your filament, your flow rate, or how much
dimensional drift you will tolerate.

## Nozzle life on non-abrasive filament

| Nozzle | Default | Basis |
|---|---:|---|
| Brass | 5,000 g | PETG widens a brass bore at ~3–5 kg; PLA reports run to ~15 kg. Set to the harsher of the two. |
| Stainless steel | 15,000 g | E3D puts stainless at ~30% the wear rate of brass. |
| Hardened steel | 50,000 g | E3D: zero observable wear at 2.5 kg of carbon/glass-filled — ten times the amount that visibly damaged brass. |
| Ruby tip | 150,000 g | Reported at 3+ years against brass at 6–12 months. The body gives up before the tip. |
| Tungsten carbide | 250,000 g | 5+ years. In practice, "replace the printer first". |
| Other / unknown | 5,000 g | *Estimate.* An unknown fitment is assumed as soft as brass — guessing generously would quietly extend a nozzle nobody has described. |

## How much faster filled filament wears it

Matched worst-first, because the strings are free text a shop typed: a spool
labelled `PLA-CF Glow` has to land on carbon fibre, which is the worse of the
two **by measurement** even though intuition says otherwise.

| Class | × | Basis |
|---|---:|---|
| Glass-filled | 15 | Reported destroying a brass nozzle after 100 g — the harshest figure found for any common filament. |
| Carbon-filled | 10 | E3D saw significant wear at 250 g; others say 1–2 kg. 10× sits between them: 500 g on brass. |
| Metal-filled | 5 | *Estimate.* No controlled test found. Below carbon fibre because the particles are softer than the nozzle in a way carbon fibre is not. |
| Glow in the dark | 3 | Measured **no** orifice change after 330 g through cheap brass. Kept above 1× only because filler loads vary hugely by brand. |
| Marble / stone / ceramic | 3 | *Estimate.* No controlled test found. |
| Glitter / sparkle | 2.5 | *Estimate.* No controlled test found. |
| Wood-filled | 2 | *Estimate.* No controlled test found; usually a clogging problem rather than a wear one. |

Four rows are still estimates. They say so in the app, in amber, because a
number nobody checked must not look like one somebody did.

`polycarbonate` is deliberately **not** matched by the carbon pattern. It is
hot, not abrasive, and an unanchored `carbon` matches it — which would have told
every PC-printing shop its nozzle was wearing ten times too fast.

## Sources

- [E3D — Are Abrasives Killing Your Nozzle?](https://e3d-online.com/blogs/news/are-abrasives-killing-your-nozzle)
- [CNC Kitchen — How much abrasive filaments damage your nozzle](https://www.cnckitchen.com/blog/how-much-abrasive-filaments-damage-your-nozzle)
- [Industrial Monitor Direct — Hardened nozzle selection for CF and GF printing](https://industrialmonitordirect.com/blogs/knowledgebase/hardened-nozzle-selection-for-carbon-fiber-and-glass-fiber-3d-printing)
- [Prusa forum — Lifetime of a nozzle](https://forum.prusa3d.com/forum/english-forum-general-discussion-announcements-and-releases/lifetime-of-a-nozzle-2/)
- [UAVMODEL — brass vs hardened vs ruby vs tungsten carbide](https://blog.uavmodel.com/3d-printer-nozzle-comparison-brass-vs-hardened-steel-vs-ruby-vs-tungsten-carbide-wear-flow-and-application-2026/)

## What the counter actually measures

Grams through **this machine** since `nozzle.installedAt`, from completed orders
only, as `(printWeight + supportWeight) × qty` — the same accessor inventory
uses to deduct filament. Each part's grams are multiplied by its material's
abrasiveness before being counted against the threshold.

Until this was fixed the sum read `p.weight`, which is not a field a part has,
so every job contributed `+undefined || 0`. Checked against a real shop: twelve
completed jobs, **2,461 g** through a 2,000 g threshold, card reading **0 g**.
The warning had never fired for anybody.

### A print marked "not business" still counts here

An order can be marked as not applicable to the business — a calibration cube, a
gift, a bracket for the shop's own shelf — which keeps it out of revenue, order
counts and every report (`lib/business-scope.js`).

It does **not** keep it out of this. The nozzle does not know who the print was
for: the same grams of the same abrasive filament went through it either way, and
a counter that ignored half a machine's work would warn late, in the direction
that ruins parts. The flag is scoped to money and trade counts for exactly this
reason, and there is a test asserting `lib/nozzle-wear.js` never consults it.
