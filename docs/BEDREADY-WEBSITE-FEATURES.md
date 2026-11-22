# Bed Ready — Feature Catalogue (for the website)

> **Purpose.** This file is the single source of truth for the Bed Ready website copy. Each section
> gives a short marketing-ready blurb plus the factual details behind it, so the website can be updated
> without digging through the app. Written for **1.0**. Keep claims honest — everything
> below reflects what actually ships.

**One-line pitch:** *Bed Ready is a free desktop workbench for solo 3D-printing makers — organise your
print files, preview them in 3D, retarget any model to the printer you own, and cost every print. It
works with your existing slicer; it doesn’t replace it.*

**Platforms:** macOS, Windows, Linux (Electron desktop app).
**Price:** Free — not a trial, not a beta discount. Every feature in this catalogue runs on your
own machine and stays free, with no licence key and no time limit. Features that need Bed Ready's
servers to work will be paid when they arrive; the line is **local vs. server**, not basic vs. pro,
so nothing that already runs on your machine moves behind a paywall later.
<!-- The paid/free line is local-vs-server. Two things follow for the site copy:
     · Don't write "free tier", "free plan" or "upgrade" — there are no tiers, and #608 already
       removed the Simple/Pro framing for the same reason. Free is the product, not an entry level.
     · Cloud sync (§8) ships today and is free. It predates this rule, which is about *future*
       server features, so it is not the first paid thing by default — but it IS server-backed, so
       if it is ever meant to become paid, say so here first; the site should not have to guess. -->
**Privacy:** Local-first. Works fully offline. No telemetry. Optional end-to-end-encrypted cloud sync.
**Status:** 1.0 — released. Feedback still welcome via the in-app Feedback button.

---

## 1. 3MF Converter — retarget any model to your printer

**Blurb:** *Got a multicolour `.3mf` made for a printer you don’t own? Bed Ready rewrites it for your
printer — keeping the geometry and colours — so it opens cleanly in your slicer.*

Details:
- Converts/retargets a `.3mf` to a different printer: rewrites printer model, bed size, nozzle, and
  print settings while preserving the mesh, colours, and multi-plate layout.
- **Targets almost any printer.** Beyond a built-in shortlist, the target list includes **every printer
  in your installed OrcaSlicer / Snapmaker Orca profile library** (1,000+ models, grouped by vendor).
  Choosing one builds the file from that printer’s own machine profile + a matching print-quality preset.
- **Native output.** The converted file carries the target printer’s real start/end/tool-change G-code
  and print settings, so the slicer recognises it as that printer instead of flagging “customised”.
- **Correct plate layout.** Multi-plate files are re-tiled onto the target bed so plates stay centred
  (a model arranged for a 256 mm bed lays out correctly on a 270 mm bed, etc.).
- **Normalize mode.** Strip vendor lock-in and save a clean generic `.3mf` any slicer opens.
- **Batch convert** many files to one target in a single run.
- **Saved presets** for target + colour mapping you reuse often.
- Always verify the result in your own slicer before printing (shown in-app).

## 2. Full Spectrum — colour mixing on a 4-slot printer

**Blurb:** *Five colours, four slots? Full Spectrum keeps four filaments physical and reproduces the
rest by mixing — no colour left behind.*

Details:
- On a **Snapmaker U1** (4 slots), converting a file with more colours than slots offers **Full
  Spectrum**: keep four filaments physical, reproduce the extras as dithered mixes of those four.
- Shows exactly **which four filaments to load** and the **recipe for each extra colour**
  (e.g. “65% White + 35% Red”), with a **ΔE** perceptual-accuracy score per mix.
- Chooses which colours stay physical intelligently — a colour no mix can fake (a pure primary, white)
  stays a real filament; only genuinely mixable colours are virtualised.
- Writes the proper Snapmaker Orca mixed-filament definitions so the printer prints the mixes.

## 3. Interactive 3D preview

**Blurb:** *See your model before you slice it — orbit, zoom, flip between plates, and preview colour
changes live.*

Details:
- Real-time WebGL 3D preview for `.3mf` and `.stl` — drag to orbit, scroll to zoom, preset views.
- **Multi-plate** files get a plate picker.
- **Live recolour** — change a colour swatch and see it on the model instantly.
- Handles detailed multi-million-triangle models.
- Correctly decodes painted/multicolour 3MF colour data.

## 4. Slicer integration

**Blurb:** *Bed Ready finds the slicers you already have and hands off to them — it never bundles or
replaces your slicer.*

Details:
- **Auto-detect installed slicers** (Settings → Slicer integration): OrcaSlicer, Snapmaker Orca,
  PrusaSlicer, Bambu Studio, UltiMaker Cura, SuperSlicer, Creality Print, ideaMaker, Simplify3D,
  Lychee, CHITUBOX, FlashPrint, and more — plus vendor OrcaSlicer forks.
- Add slicers manually and pick a default.
- The converter reads printer/filament/print **profiles from your installed slicer** — nothing is
  downloaded; install/update the slicer and new printers/filaments appear.
- On a Snapmaker U1 you can choose the **exact filament in each slot** from your Orca library and the
  **print-quality preset**, written into the converted file.

## 5. Print-file library

**Blurb:** *A tidy home for every model — with notes, tags, the profile you slice it with, and its
converted versions.*

Details:
- Organise `.3mf`/`.stl` files with names, tags, material, notes, favourites.
- Attach the slicer profile you use and keep converted variants alongside the original.
- Fast search and previews.

## 6. Inventory & costing

**Blurb:** *Know what a print costs and what’s on your shelf.*

Details:
- Track filament spools (material, colour, remaining weight).
- Per-print cost estimate (material + time + machine).
- Colour-matching: the converter can hint the nearest filament you have in stock for each slot.
- A lightweight print queue to see what’s next.

## 7. One toolset, no modes

**Blurb:** *Everything is there from the first launch — nothing to unlock or switch on.*

Details:
- Bed Ready has **no Simple/Pro switch**. Every maker tool — converter, 3D preview, print-file
  library, colour studio, inventory, costing, queue — is present from the start.
- Modes are a **Khayt** concept, not Bed Ready's. The app pins itself to its single
  commerce-free experience and hides the switcher entirely, so a site that offers "start
  simple, upgrade later" is describing a control the visitor will never find.

## 8. Your data, backups & privacy

**Blurb:** *Your files, your computer. Offline by default, with easy backups.*

Details:
- **Local-first**: works fully offline; nothing is uploaded by default; **no analytics/telemetry**.
- **Backups & restore points**: export a full backup, set restore points before big changes.
- **Optional cloud sync**: opt-in, **end-to-end encrypted** — only you hold the key; no account needed
  to use the app. Free today; it is the one server-backed feature that predates the paid-server rule
  in the header.
- 8 UI languages (English, Arabic, German, Spanish, French, Japanese, Turkish, Chinese).

---

## 9. Printer monitoring — watch the machines from the app

**Blurb:** *Add the printers you own and Bed Ready keeps an eye on them — progress, temperatures, and
a notification the moment one stops.*

Details:
- **Finds them for you.** mDNS discovery turns what a printer advertises on the LAN into "here is a
  printer you can add", so nobody types an IP address. The service names and TXT keys were taken from
  real hardware — a Prusa CORE One (`_prusalink._tcp`) and a Snapmaker U1 (`_snapmaker._tcp`) — not
  from documentation.
- **Speaks what printers already speak.** Six adapters, and these are the six a shop can actually
  select when adding a machine: Bambu, Moonraker (Snapmaker U1, Klipper), OctoPrint, PrusaLink, Duet
  and Repetier. Each firmware reports progress differently; Bed Ready normalises them to one shape,
  clamped 0–100, so a printer reporting something unexpected cannot render as 50,000,000%.

  **Still not SDCP / Elegoo resin on the website — and the reason changed on 2026-08-24.** It used
  to be that there was no adapter at all: `sdcp` appeared nowhere in the code. That is no longer
  true. The socket layer landed, `sdcp` is in the picker at `renderer/machines.js`, discovery finds
  these printers and the queue reads their status. Seven adapters exist.

  The website may still name **six**, because the seventh **has never met a printer**. There is no
  Elegoo on the bench; the protocol and the network handling are covered by tests and the discovery
  broadcast has been run against a live LAN, but whether a real mainboard answers it is unproven.
  A shop that buys on the strength of a website line and finds it does not work has been misled by
  us, not by its printer.

  So: the app offers it, marked as untested in the CHANGELOG, and the website waits for hardware.
  The moment a Mars or a Saturn confirms it, this paragraph is what to come back and delete.
- **Shows** state, progress, current filename, time remaining, nozzle and bed temperature, and the
  error text when there is one.
- **Tells you when a printer stops.** Alerts come from diffing one poll against the last, with a
  per-printer cooldown so a machine flapping on a bad network does not shout every few seconds.
- **How it tells you, in Bed Ready:** an in-app toast, and an OS desktop notification when the window
  is behind something else. **Not** Telegram, email or webhooks — those exist in Khayt, the business
  app, and a maker at the bench wants the app and the OS to say it, not a chat channel.

**Per-printer camera — shipped, and safe to write about.** `lib/webcam.js` does mjpeg/HLS, rotation,
timelapse modes, capability read from the printer rather than guessed, and a snapshot proxy pinned to
the printer's own host so it cannot be used as an SSRF pivot. `renderer/bedready.html` loads it (#588,
2026-08-03), which is what makes `machines.js`'s `typeof KhaytWebcam !== 'undefined'` guard true.

Verified in the source **Bed Ready 1.0.0 was actually built from** — the release notes name it
(`KhaytApp/Khayt@bef8f8d`), and the script tag is present there — so the camera is in the shipped
1.0.0, not merely on `main`.

**Both flavour-gating questions are now answered, in the running app rather than off the tree** — the
assertions live in `scripts/e2e-bedready-smoke.mjs`, so the answers stay true or CI says so.

- **Reaching printers.** There is no top-level "Printers" view in either flavour; printer setup is a
  section of Settings, and in Bed Ready it is reachable with no Pro or business gate on it. Do not
  write copy that sends someone to a Printers tab.
- **The adapters.** The same six in both flavours. Nothing here is Khayt-only.

**But say "scan", not "set up".** The manual connection fields — the adapter dropdown, host and port —
sit in a Pro-only block, and Bed Ready runs permanently in the commerce-free mode that hides it. The
maker's route to a connected printer is **Scan network → Use**, which lives outside that gate and
fills those fields in for them.

So the line above about mDNS meaning "nobody types an IP address" is not a convenience claim in this
app — it is the mechanism. Nobody *can*. Copy that says "add your printer's IP" describes something a
Bed Ready user cannot do, and a printer that does not answer discovery cannot be added at all. Worth
knowing before the website promises otherwise.

## Website checklist / notes

- Do **not** badge the product as beta. 1.0.0 is released, and the app carries no beta labelling —
  a "public beta" badge on the site now contradicts what a visitor downloads. Keeping backups is
  still worth saying; "expect rough edges" is not.
- Include the safety line: *Always review a converted file in your own slicer before printing.*
- Trademarks: Snapmaker, Bambu Lab, Prusa, Creality, UltiMaker, etc. are trademarks of their owners;
  Bed Ready is **not affiliated with or endorsed by** them. Product names are used for compatibility
  reference only.
- Licensing: source-available under **FSL-1.1-Apache-2.0**. See `CREDITS.md` for third-party notices.
- Contact / feedback: the in-app **Feedback** button opens **bedready.io** (the site should host a feedback/contact route). Bed Ready does **not** route users to Khayt's support inbox.
- Do **not** claim Bed Ready slices or prints — it complements a slicer, it doesn’t replace one.
