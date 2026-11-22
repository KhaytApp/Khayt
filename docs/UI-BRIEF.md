# Khayt — a brief for designing the interface from scratch

Paste this whole document. It describes the product, the people who use it, the
screens that exist, the constraints that are not negotiable, and what is
currently wrong. It deliberately does **not** describe a visual style: that is
the thing being asked for.

Pair it with `docs/ABOUT-KHAYT.md` if you also need the product and market
context. This one is about the interface.

---

## 1. What the software is, in one paragraph

Khayt keeps a 3D printing shop's book. Not a printer monitor and not a generic
ERP — the business itself: the jobs the shop has taken, what each one actually
cost in filament and machine time, what was charged, what is on the shelf, what
the printers are doing, and what any of it earned. It is free, works fully
offline, and stores everything in one JSON file on the shop's own machine. An
optional end-to-end encrypted cloud syncs that file between machines and gives
customers a page to follow their order on.

**This brief is for the macOS app**, which is the product. A second app built in
Electron exists for Windows and Linux and is secondary.

## 2. Who is using it, and in what state

A shop owner or the person at the bench, on a Mac, usually **while doing
something else**: a print has finished, a customer is on the phone, a machine is
mid-job. Sessions are short and interrupting. Almost nobody sits down to "use
Khayt" for an hour.

Three things follow from that and should shape everything:

- **A glance has to answer a question.** What is late, what is running, what is
  owed, what is about to run out.
- **The common path has to be short.** Taking a job, moving it a stage, marking
  it paid.
- **Being wrong is expensive.** This is a shop's money and stock. A figure that
  is subtly wrong is worse than a figure that is missing, and the interface
  should never imply certainty it does not have.

Shops are **one to twenty machines**. Above that, enterprise MRP; below it, a
spreadsheet.

## 3. The surfaces that exist

Sixteen top-level places, reached from a sidebar:

| Surface | The question it answers |
|---|---|
| **Dashboard** | what needs me right now |
| **Jobs** | everything taken, filterable by stage |
| **Board** | the same work as a kanban, dragged between stages |
| **Library** | the shop's 3D models, as projects and files |
| **Catalogue** | products the shop sells, made from those models |
| **Customers** | who they are, what they have ordered, what they owe |
| **Machines** | what each printer is doing, and what it is due for |
| **Inventory** | filament on the shelf, and what is running out |
| **Expenses / Waste** | what was spent, what was scrapped |
| **Reports / Portfolio** | what the shop earned, and what it has made |
| **Calculator / Colour** | pricing a print, and planning filament colour |
| **Gift cards** | issued, redeemed |

Plus **19 modal sheets** for editing one thing: a job, a product, a machine, a
spool, a customer, a payment.

The app is about **137 Swift view files**. This is not a small surface.

## 4. The data, at real scale

Design against **real quantities**, not three rows of placeholder:

- One live shop today: **152 model files, 19 jobs, 3 spools, 2 machines,
  2 products**, with **83 of the files in no project at all**.
- The bundled sample shop: **42 jobs, 31 customers, 20 products, 15 models,
  13 spools, 5 machines, 9 expenses, 6 waste entries**.
- Libraries of **several hundred models** are the case that matters; a model
  file can be 100 MB+, and a shop owns 8–16-million-facet files.

A screen that looks good with five rows and collapses at two hundred has not
been designed.

## 5. Constraints that are not negotiable

**Both languages, equally.** English and Arabic, and Arabic is **right to
left** — the whole layout mirrors, not just the text. Arabic is not a
translation afterthought: this was built first for a Saudi shop. Any design that
only works in one direction is not usable.

**Both appearances.** macOS light and dark, with a real palette on each side —
not one palette dimmed.

**Contrast is measured, not eyeballed.** Text and meaningful marks are checked
against WCAG ratios. A colour that reads well on the designer's display and
fails at 4.5:1 will be rejected by a test, not by taste.

**Colour can never be the only signal.** State — late, running, failed, paid —
must survive being seen by someone who cannot distinguish the hues.

**The smallest screen wins.** A 13-inch laptop is the real machine. A modal
sheet on macOS is pinned to its window and **cannot be dragged**, so a sheet
taller than the display hides its own buttons — this happened, and a shop could
not close a product it had opened.

**It is a native Mac app.** Keyboard, menus, undo, drag and drop, Quick Look and
the context menu are expected to work as they do elsewhere on the system. A
design that reads as a web page in a window is wrong, however pretty.

**Money and units are localised.** Currency symbols sit on the correct side per
currency, the Saudi Riyal has its own glyph, and quantities carry units the shop
recognises.

## 6. What the current interface gets wrong

Honest list, from real use. These are the problems worth solving, not a
complaint about aesthetics:

1. **Density with no hierarchy.** Screens show a lot and rank little. On a
   glance-driven app, the eye should be led; today it is left to search.
2. **Grouping barely exists.** Until this week a project of forty files looked
   like forty files — a group was a filter in a sidebar and had no presence on
   screen. Projects are only now becoming folders.
3. **Filtering is thin.** Search plus one axis. A library of hundreds needs to
   answer "the busts in the Saudi Kings" and "what have I not filed yet".
4. **Sheets are walls of fields.** Nineteen of them, some with thirty-six
   inputs, in one long column with no rhythm or grouping.
5. **Empty states teach nothing.** A shop that has just installed sees blank
   screens rather than a way in.
6. **Nothing carries the brand.** The app wears the system's clothes. There is
   an icon and a palette and almost no expression of either.
7. **Inconsistent components.** The same idea — a chip, a section, an action
   row — has been hand-rolled repeatedly at different sizes. A real component
   set with rules would fix a class of drift.

## 7. What must not be lost

Some of the current behaviour is deliberate and hard-won. A redesign should keep
the **principles** even as everything visual changes:

- **Say what is true, including when it is unknown.** A missing figure is shown
  as missing, never as zero. "No answer yet" and "zero" are different states and
  are drawn differently.
- **A destructive or outward-facing action is deliberate.** Sending a customer
  an email, publishing a link, moving a job that triggers either — these are
  distinct from ordinary edits and should feel it.
- **Failure is said out loud.** When something does not reach a customer, the
  shop is told in a sentence it can act on, not a code.
- **Escape always closes a sheet.** It is the difference between an annoyance
  and a trap.
- **Numbers are net of tax where it matters** and gross where it matters, and
  the interface must not blur which.

## 8. What is wanted

A complete visual and interaction system for a native macOS app:

- A **palette** for light and dark that passes contrast, with defined roles
  (brand, state colours for running / late / done / attention, surfaces, text).
- **Typography** with a real scale, working in Latin and Arabic.
- **Spacing, radii and elevation** as a small set of tokens.
- A **component set**: the chip, the section, the action row, the table row, the
  card, the empty state, the sheet — each with its states.
- **Layout patterns** for the three shapes that recur: the dense table, the
  media grid (models and products), and the edit sheet.
- **Iconography** that reads at small sizes, alongside the existing app icon.
- How the system behaves **at laptop height and in RTL** — shown, not asserted.

The brand icon is orange on navy; the interface accent is currently the navy,
not the orange. That is a decision the new system may revisit, but it should be
revisited on purpose.

---

*Everything factual above was read from the running app and its data rather
than recalled: surface names from the navigation, counts from a live shop's
book and the bundled sample, constraints from the tests that enforce them.*
