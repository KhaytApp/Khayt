# Khayt — the automation line (R10)

*Written 2026-11-04. This is R10 from [KHAYT-COMPETITIVE-ROADMAP.md](./KHAYT-COMPETITIVE-ROADMAP.md) §6,
ranked idea 6 in §7.*

Khayt is the books and the front counter of a small print shop: quotes, jobs, customers, stock, money
and tax, with the printers wired in so those books are true. It is not a print-farm robot. Printago,
SimplyPrint, 3DPrinterOS, Bambu Farm Manager, SnapCon and FlowQ compete on automation. Khayt does not
race them there; it reads what their printers did and puts it in the books.

This page says where the line falls, so a new competitor or a new feature request does not reopen the
question one feature at a time. Changing a line here is allowed, and is done here first, in writing,
before any code.

## Khayt does

- **Reads every printer it can reach.** It reads state, progress, time left, faults and what the job
  actually used, and puts those figures on the job.
- **Sends a file the shop chose to a printer the shop chose**, and pauses, resumes or stops it,
  including from the phone.
- **Proposes what goes where next** (`lib/auto-dispatch.js`). It shows the reason, waits for a person
  unless the shop has turned that confirmation off, and never offers a printer whose plate may still
  hold the last part.
- **Takes the shop's word that a printer clears its own plate** (`clearsOwnBed`: belt printers, plate
  changers, push-off end routines). The shop declares it per machine; Khayt never guesses it.
- **Passes on the printer's own failure detection** (Bambu's AI print monitoring, for example) as a
  fault on the job.
- **Schedules maintenance** and counts machine hours, cost and downtime against the books.

## Khayt does not

- **Cloud slicing.** The shop slices in its own slicer. Khayt reads the sliced file and never produces
  G-code.
- **Generating ejection or plate-cycling G-code.** A bad push-off sequence wrecks a machine. Tools like
  FARMONE and FlowQ build those files; Khayt runs and records them.
- **Lights-out production.** Khayt does not start a print nobody agreed to, and does not chain jobs
  without a person or a shop rule (`clearsOwnBed`, confirmation off) saying it may.
- **Its own camera AI** for spaghetti or warping. Where the printer has detection, Khayt relays it.
  Building vision is a different product.
- **A connector for every marketplace.** Salla, Zid, WhatsApp, Shopify and Etsy are in; Printago's
  weekly ShipStation/TikTok/Walmart releases are not a race worth running (§7, "Deliberately not
  doing").
- **Institution billing**: per-user print quotas, charge-per-gram cards, PaperCut. That is
  3DPrinterOS's school market, not a shop's.
- **Being the accountant's software.** No double-entry ledger. Khayt exports to Wafeq, Daftra, Xero,
  Zoho and QuickBooks.

## How to use this page

When a feature request or a competitor's release lands on the "does not" side, the answer is a link to
this page, not a new argument. When the shop's real use shows a line is wrong, change it here, then
build.
