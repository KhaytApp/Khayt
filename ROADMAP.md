# Khayt engineering roadmap

Living priorities for maintainers. Not a public commitment calendar — reorder as the product needs.

## Now (post-3.7.0, the Electron line closed — on `main`)

**Stable is v3.7.0**, PUBLISHED 2026-09-11 on all three platforms and verified
manifest-by-manifest (see [docs/RELEASE-HOLD.md](./docs/RELEASE-HOLD.md)) — the
3.7.0 line, cut from `main` rather than
promoted from `v3.7.0-beta.25` unchanged, because 225 commits had landed since
that cut: the money corrections, the measured-actuals chain and three dependency
security fixes. The promotion gate and the one condition WAIVED are recorded in
[docs/RELEASE-HOLD.md](./docs/RELEASE-HOLD.md).

**Khayt for macOS is being rebuilt native**, sharing this app's business rules
unchanged rather than reimplementing them. It becomes the main Khayt on macOS, a
native Windows app follows, and the Electron build continues as the third option.

### Mac parity — where it actually stands (2026-09-12)

The Mac app is the product now, so a renderer-only feature is a gap to close,
not a difference to document. The measurable form of that: **129 of `lib/`'s 244
modules are bundled into the Mac app. 115 are not**, and 35 of those cannot be —
they need Node's `fs`, `crypto`, `zlib` or `http`. **80 are pure and could be
bundled today.**

Seven landed on 2026-09-12: `maintenance`, `consumable-reorder`,
`consumable-categories`, `print-setups`, `print-versions`, `print-file-parts`,
`zatca-submit`.

Three things that recur and are worth knowing before picking the next one:

- **The sample book cannot reach a new feature.** Four in a row arrived with
  `sample-shop.json` at zero for them, so every branch of every new panel would
  have shipped never having been drawn. Adding the sample data is part of the
  feature. `mac/KhaytCore/Tests/KhaytAppTests/SampleShopTests.swift` guards the
  spread, and two of those guards pin `now` — a rate measured over a trailing
  window, and a date-driven interval, both decay out of the case they were
  written for if the guard reads the wall clock.
- **A module named for what it produces fails the bundle check.** The global is
  derived from the filename; `print-file-parts.js` publishes `KhaytPrintParts`
  and every engine refused to start until it was in the exceptions map. That is
  the check working.
- **A rule that composes an English sentence cannot cross.** `describeSetup` and
  `describe` both do. The FIELDS cross and the line is built against the locale;
  the VERDICT stays in the rule.

**What is left, in the order it is worth doing:**

| | What | Why it is not done |
|---|---|---|
| 1 | **Depreciation in the cost model** (R8, §6 of the competitive roadmap) | Not a parity item at all — a correctness gap in both apps |
| 2 | **A job part editor** | Parts are read-only on the Mac. Unblocks `part-from-print-file.js`, which is otherwise a module with no caller |
| 3 | **`print-risk.js`** | Needs a decision: `analyzeTriangles` is two-pass over the mesh, and the Mac's reader streams and never holds triangles. On demand (second read of the file) or at import (every import pays)? Also the only item needing a Swift duplicate of an accumulator |
| 4 | **`rbac.js`, `subscriptions.js`, `feature-tiers.js`** | Pure and unbundled. Tier and permission rules the Mac currently has no opinion about |
| 5 | **`stl-parse`, `obj-parse`, `gcode-parse`, `gcode-geometry`** | The Mac parses meshes in Swift on purpose (licence — `Mesh.swift` explains). These are for the formats it cannot yet read, not a lift |
| 6 | **The seven `ai-*` modules** | Needs a product decision about what leaves the shop and an API-key path, not an engineering one |
| 7 | **`lan-server.js`** | Node `http`. Wants `LanServer.swift`, which compiles and nothing constructs |


**Previously: v3.6.0** (2026-08-21) — the 3.6.0 line, promoted from
`v3.6.0-rc.4` unchanged after a seven-day soak. rc.4 was the first candidate on
this line that `main` did not overtake, so for once replace-vs-promote resolved
to *promote*; rc.1, rc.2 and rc.3 were each replaced instead.

**`v3.7.0-beta.25` is PUBLISHED** (2026-09-03) — all three platforms, from
`120e370`, with every asset its three manifests name verified to serve 200. It
is the review cut: twenty-two passes over the app and the cloud, and the money
and data-safety faults they turned up.

The money a shop would have got wrong. A **VAT return that declared no VAT at
all** — boxes 1 to 3 read fields nothing in the app ever writes, so a shop owing
SAR 52,173.92 filed a nil return with its sales overstated by the same amount. A
**payment plan that billed the deposit twice**, and — once that was fixed — an
order paid in full that never showed as settled. A **split job counted twice**
in receivables with its deposit stranded. **Loyalty points** awarded for
cancelled, refunded and personal jobs. An **invoice QR that scanned and was
invalid**, because an empty VAT tag looks exactly like a valid one.

The data a shop would have lost. Every **backup, iCloud copy, restore point and
pre-update snapshot silently off above 20 MB** while saving worked to 50. **Crash
recovery preferring a two-month-old orphan** over yesterday's save, under a green
tick. **Two shop-floor tablets overwriting each other** after the server had
answered 201. The **printer's measured figures deleted on every save**.

What a customer saw. A **delivered order showing no progress at all**. A
**review nobody could see or remove** moving the shop's public rating. And
**sixty-five messages only ever in English**, including the one that appears
when a data file will not open.

**`v3.7.0-beta.24` is PUBLISHED** (2026-09-02) — all three platforms, from
`6de15f2`, with every asset its three manifests name verified to serve 200. It is the cut that lets a
library grow: model previews leave the store for the folders beside the models.
A record is 914 bytes; the same record carrying its preview is 14,900, so the
picture was 94% of it and five thousand files came to 71 MB against a 50 MB
ceiling — past which every save is refused and a shop loses its day at the next
launch. On disk, ten thousand files is 8.9 MB. **No database was needed; the
store was never big, its images were.**

It is also the FIRST release to carry a `### Before you update` section, which
is the consent gate from `beta.23`'s own work being used for the first time: it
moves data, so it asks first and will not download until the shop accepts.

Also carries print versions (big and small, coloured and plain — each with its
own time and weight, folded out of `converted[]` rather than added beside it),
tags that stay one tag, and a search that no longer redraws the whole library on
every keystroke.

**`v3.7.0-beta.23` is PUBLISHED** (2026-09-02) — all three platforms, from
`7f0699c`, with every asset its three manifests name verified to serve 200. It exists because a shop
could not add its own files. A print file over about 50 MB joined the library
holding no print time, no weight, no material and no picture — and said nothing,
so the import looked like it had worked. Four separate size ceilings governed
one act of reading a file (150/50/60/50 MB), and past any of them every refusal
was shaped like an answer: `{ok:false}` is truthy, `null` is what a missing file
returns, `empty` is what a 3MF with no thumbnail returns, and every caller read
them as answers.

Underneath it, reading a mesh ALLOCATED the mesh: `parseStl` built a list of
every triangle whether or not the caller wanted one, so a 250 MB STL cost
1,488 MB of heap and 1,459 ms — now 4 MB and 164 ms, with the numbers asserted
EQUAL to the old parser rather than close. A 3MF was worse at roughly 68x its
own size, because `_extractCore` materialises twice; `measureMesh` folds each
facet into a running total instead. Measured on the shop's own library — 3,415
models, 30.6 GB, the 3MFs running 8-16 MILLION facets and none of them sliced,
so the mesh is the only place their numbers can come from. Those three files now
measure in about nine seconds and 5-35 MB of heap; they did not finish at all
before.

It also carries one action row and one overflow menu across eight screens (the
print library, both queues, clients, the waiting list, quotes, products and the
converter), Khayt's own line icons in place of emoji, and forty strings that
were still English in German, Spanish, French and Chinese.

**`v3.7.0-beta.22` is PUBLISHED** (2026-09-01). The cloud caps one published
picture at a fixed size and DROPS anything larger rather than refusing it, so a
publish reported success and the picture was simply gone — which is what
happened to the first catalogue to publish at the new size, reported from the
live payload by the integrator reading it. The app no longer sends what the
server will not keep, and no longer sends each listing's main photo twice: the
storefront needs a `photo` field beside the gallery and it was being uploaded a
second time rather than derived at the other end, uncounted by the budget that
decides how many pictures a catalogue can carry.

**`v3.7.0-beta.21` is PUBLISHED** (2026-09-01). It exists because the
same Medusa integration that produced `beta.20` needs two things a catalogue could
not tell it. A product's print time, weight and material were all known to Khayt —
print hours are what work out when a job can start — and none of the three were
ever published, so a shop typed each one again into its storefront's admin, where
it drifts. And a published photo was the 240px thumbnail built for the product
grid, which was also serving as the HERO IMAGE on the storefront's product page:
measured on the live catalogue, 240x240 and 180x240. The full picture had been
written to disk on save all along and nothing ever read it back. Both only reach a
shop through an installed build, which is the whole reason to cut.

**`v3.7.0-beta.20` is PUBLISHED** (2026-09-01). It exists because
of the first real Medusa storefront integration: the subscriber Khayt hands a shop
to paste asked only for the line item, and `material` is a native PRODUCT column,
so it arrived empty on every order request with nothing to show anything was
missing. The same file also still told shops to swallow a failed import, on advice
that expired when the cloud's import endpoint became idempotent. Both are fixed,
and the corrected template only reaches a shop through an installed build. `beta.19` (2026-09-01) remains published. A shop can give
its storefront a readable web address — `/shop/your-shop-name` rather than a long
id — with the original link never breaking and a renamed one still working for
ninety days. The cloud's emails are bilingual too; they were English only,
including the sign-in code a CUSTOMER receives. `beta.18` (2026-08-31) carried
the camera-header security fix and remains published. It carries a
SECURITY fix — a device answering a printer's camera URL could send a content
type that escaped the image tag and ran script inside the app — along with a
default working week that was four days and matched no calendar anywhere, a
catalogue that silently discarded every description typed into it, and the last
of the interface that was English in all nine languages. It **replaces
`beta.16` as the promotion candidate** — the promise lives in
[docs/RELEASE-HOLD.md](./docs/RELEASE-HOLD.md), not in the version string. All
three platforms, `BUILD_MAC` set.

`beta.17` is the same day's work carried further: everything `beta.16` shipped,
plus the storefront finally syncing what the catalogue already knows (prices and
photos, rather than a second form to fill in), a print that can be marked as not
business, the machines page showing what each printer is actually doing, hover
descriptions that appear when you hover, and a sidebar that says whose shop this
is. `beta.16` is superseded rather than withdrawn.

It carries the content-language work — a shop picks one or two of nine
languages and writes its products, clients and documents in them — and, more to
the point, **eighteen places that had been reading that text as an
English-or-Arabic pair**. Those were not found by testing the feature; they were
found by asking, four times, what the passes could not see. Two of them sent
customers a message with the name missing. Two more submitted ZATCA e-invoices
with the seller's street blank, from a settings key that has never existed. One
made the whole storefront feature inert in production: the server's catalogue
whitelist silently dropped every field the app had been sending.

`beta.15` is superseded rather than broken: everything in it is here too.

**`beta.14` cannot accept a catalogue photo.** The multi-image editor shipped
with a live `FileList` read after the input was cleared, so picking an image did
nothing at all — no photo, no error, no console message. Every unit test passed;
the bug lived in the one line between a correct module and a wiring test that
found the listener.

Repairing that surfaced a worse one underneath it: **every photo on a product
was written to the same filename.** The editor showed three thumbnails, the
store held three records, the disk held one picture, and removing any of them
would have unlinked the file the others still used. Found by reading the disk
rather than the screen.

Then, asked whether this was ready to cut, driving the screens rather than
re-running the suite found two more:

*The dashboard nozzle alert was dead on every theme.* Every theme replaces
`renderDashboard` with its own and none of them draws `.dash-section`, so the
warning existed on the machine card and on no dashboard. It goes through the
attention bar now, which the themes do render — verified on all seven.

*Meridian's attention bar had never worked.* It called `KhaytAttention.compute`,
a function that does not exist, behind a `typeof` guard that made the missing
function indistinguishable from a missing module. It has shown "All clear" since
it shipped, through offline printers and late orders alike.

**Also corrected: a story, not a defect.** A U1's nozzle threshold changed from
2,000 g to 50,000 g minutes after an update, and I attributed it to code written
the same day. The shop had typed that number. A reproduction of the ordinary
path had already come back clean and that should have ended the theory. The
CHANGELOG entry claiming it, and the comments repeating it, are gone — the
behaviour it prompted was independently wrong and is still fixed.

Five things this session were built, tested and never plugged in — the support
link that was explicitly asked for among them. The pattern each time: a correct
module, a wiring test that finds the listener, and nothing driving the actual
screen. A green suite is not evidence that a feature exists.

**The newest *published* pre-release is `v3.7.0-beta.25`** (2026-09-03) — all
three platforms, published from `6de15f2` on the tag push, with every asset its
three manifests name verified to serve 200. `beta.23` (2026-09-02) is superseded
rather than withdrawn.

**Its notes had to be repaired by hand after publishing**, and the reason is
worth keeping: the release-creating job had never checked the repo out — it only
ran `gh` — so `node scripts/changelog-section.js` failed with *file not found*,
the fallback published the old boilerplate line, and the build was green
throughout. The job has a checkout now and
`test/update-consent-wiring.test.js` refuses one without it. **Do not recommend
anything before it to a shop that does not write English or Arabic**: its own
name, its clients' names and the seller address on its ZATCA e-invoices all
came out blank. `beta.14` cannot accept a catalogue photo at all.

*(A release was published earlier the same day under an `rc` prerelease tag, and
has been deleted, tag and all. electron-updater's ladder knows `alpha` and `beta` and nothing else, so an
`rc` was a custom channel no beta install could reach — a shop on `beta.10` asked
for updates and was offered `beta.10`. It also sorted above every beta on the
line. See VERSIONING.md and `test/updater-channel-ladder.test.js`.)*

No hold is active — see [docs/RELEASE-HOLD.md](./docs/RELEASE-HOLD.md).

**Bed Ready is on its own line and is current: `1.2.0`** (2026-08-28), built by
CI from this repo and published to `KhaytApp/bedready`, all three platforms.
Verified after the publish rather than assumed: all three manifests read
`version: 1.2.0` and each of the five binaries they name serves 200.

It is `1.2.0` and not `1.1.1` because it carries a feature — **a Bed Ready user
can install a design somebody else made** ([#758]–[#761]), which is the first
time that machinery has been usable at all: designs lived inside `app.asar`,
read-only and replaced whole on every update. Same rule that made `1.1.0` a minor
for Kits.

The number of shared commits it inherits is the part worth recording, because it
is not what a glance at the flavour-specific files suggests. Between the `1.1.0`
build point (`846a66a`) and this cut, `main` took **100 commits, 48 of them
touching code Bed Ready runs** — but only two touch a `bedready-*` file. Counting
the flavour's own files says "two commits, ship a patch"; counting what the
flavour LOADS says otherwise. Bed Ready is a flavour of one codebase, not a
separate app, so its release size is decided by `renderer/bedready.html`'s script
list, not by filename.

It had previously sat on 1.0.0 for nine days with Kits and an accessibility fix
unreleased, because the lane was believed to be blocked on a token that in fact
already existed.

**That claim did not survive 2026-08-25.** This file said on 2026-08-24 that there
was no queue of code waiting to be written, and it was wrong in a way worth
recording rather than quietly editing out: six printer defects existed, five of
them reporting a wrong number indefinitely, and this file did not know because
nothing threw and nobody owned the printer. "No queue" meant "nothing on the
list", and the list was built from what breaks loudly.

The audit that found them is now a standing item, not a one-off —
[docs/PRINTER-PROTOCOL-AUDIT.md](./docs/PRINTER-PROTOCOL-AUDIT.md). There is one
printer on this bench and seven protocols; for six of them the vendor's
documentation *is* the test fixture, and a fixture nobody re-reads rots. Re-run it
when a vendor ships a major firmware line.

**Re-run on 2026-08-27** ([#764]), triggered the way that file says it should be
— OctoPrint shipped a major line (2.0, in RC). It found three more, and the worst
of them is a comment on the first run rather than on the code: **Repetier was
still reporting Idle / 0% on every printing machine**, the exact symptom the
2026-08-25 pass had crossed off. That fix was real and addressed a different
cause of it; `done` and `job` are on `listPrinter` and were being read off
`stateList`, where they have never been. It also found that OctoPrint's 409
("no printer is connected to me" — most of a normal day) failed the whole poll
and printed `HTTP 409` on the dashboard.

Two things worth carrying out of the second run. The first is that the audit
found this defect **and filed it as needing hardware**: it sat in *Known gaps* as
"if a real server reports 0% while printing, that is where to look". It needed a
second document, not a printer. The second is that the test written with the
first fix could not have caught it — it invented a payload Repetier does not send
and asserted against a copy of the adapter written inline in the test.

The general lesson, because it is not printer-specific: **verify a field's
provenance, not its units** — and then ask **which call the field is on**, and
**what arrives when nothing arrives**. The 2026-07-31 pass checked every unit and every unit
was right. "Is this in mm?" is answerable from documentation; "is this measured or
predicted?" usually is not, and that is the question that had OctoPrint reporting
a variance of zero against its own estimate.

Below this line, the items still need a switched-on printer, real shop use, or a
calendar. The adoption endpoint (khayt-cloud#19) left a 30-day wait rather than a
task; R7 ([#743]) left a hardware dependency rather than a task.

- [x] **A retried storefront webhook still becomes a second order — in the
      cloud.** **Done 2026-08-25** (khayt-cloud#22). [#745] had fixed this for
      Salla and Zid on the LAN server; the cloud import route — how every *other*
      storefront reaches Khayt — never got the fix, and was worse off than the
      LAN path had been: a bare `INSERT` with no duplicate check of any kind,
      where the LAN path at least had an in-memory ten-minute guard.

      Closed with a **unique index** rather than a lookup: `intake.source_ref`
      plus `UNIQUE KEY (shop_id, source_ref)`, written by a single
      `INSERT … ON DUPLICATE KEY UPDATE`. A check-then-insert would have been
      wrong for the case that actually happens — a provider retries *because the
      first delivery was slow*, so the retry tends to land while the original is
      still being written, and a check would close every case except that one.
      `source_ref` is NULLable so manual requests and portal re-orders are
      untouched, and a delivery carrying no usable reference is still written
      rather than refused.

      Running the contract suite against **PHP** rather than only Node then found
      an older defect it was not looking for: that route had been answering
      `"id":"0"` for every storefront order ever imported, because
      `lastInsertId()` reports the last insert on the *connection* and
      `notifyOwnerOfIntake` runs its own queries first. The customer-intake route
      forty lines below had always read it correctly. Nothing compared them,
      because no test had ever looked at the id this route returns.

- [x] **Soak the candidate, then promote it to `v3.6.0` stable.**
      **Done 2026-08-21** — promoted from `v3.6.0-rc.4` with no code change
      between the two: the only commit `main` had taken since the tag was
      [#711], which touched this file and `docs/RELEASE-HOLD.md` and nothing
      else. Seven days on the pre-release channel, the longest soak any
      candidate on this line got, and the first one `main` did not overtake
      while it sat.
- [x] **Flip `DELTA_WRITES`.** **Done 2026-08-21.** It turned out never to have
      been blocked on adoption: the server gate refuses an un-eligible shop with
      **404**, which is the status the desktop already falls back on, so such a
      shop keeps blob-syncing with no error and nothing for its owner to do. It
      takes effect in the next release — there is no open prerelease line, so
      that is `3.7.0-beta.1`.
- [ ] **Flip the portal read gate.** Built, deployed and dormant. Until it is on,
      the fix for "anyone with a portal link can read the whole message thread"
      is only *closable*, not closed.
      **It is no longer waiting on anything that has to be built.** The endpoint
      that measures adoption —
      [docs/KHAYT-CLOUD-ADOPTION-ENDPOINT.md](./docs/KHAYT-CLOUD-ADOPTION-ENDPOINT.md)
      — shipped as khayt-cloud#19 on **2026-08-24**, in both backends. The gate's
      own predicate now runs on every portal read and, while the gate is off,
      *counts* what it would have refused instead of refusing. The question
      stopped being a guess.
      What is left is a wait. The condition is
      `wouldRefuse.byCaller.desktopBearer` at **zero for a full `windowDays`**,
      not merely at the instant of reading — a shop that opens its Messages tab
      once a month is exactly the shop this protects. The window starts when #19
      reaches production, so the earliest this can honestly be proposed is
      **2026-09-23**, and only if the number is actually zero:
      ```bash
      curl -s -H "x-admin-secret: $S" https://cloud.khaytapp.com/v1/admin/adoption \
        | python3 -c 'import json,sys; g=json.load(sys.stdin)["portalReadGate"]; print(g["wouldRefuse"])'
      ```
      **Asked and held on 2026-08-21** on the crude proxy: three hours after
      v3.6.0 shipped every one of its assets stood at zero downloads including
      `latest.yml`, so flipping would have 401'd the Messages button across the
      whole field. That proxy has since stopped saying no; it was never able to
      say yes, which is what #19 is for.
- [x] **Verify the actuals reader against real hardware.** ~~Never met a
      printer.~~ **Done 2026-08-01** — read live and mid-print from the
      Snapmaker U1 on stock firmware; every field name correct, and
      `print_duration` vs `total_duration` differed by 571 s on that job, so
      preferring the former is now measured rather than argued. Doing it
      surfaced two further defects that no fixture could have
      ([#556], [#557]).
- [x] **`captureCompletion` against a real finish.** ~~Never seen one.~~
      **Done 2026-08-02** — 641 samples across a five-hour job, capture verified
      on the printing→complete transition at 140.96 g / 18,517 s, against the
      slicer's own 5h17m estimate: 2.6% apart. The chain is now verified end to
      end. Starting the NEXT print immediately then exposed a further defect
      no fixture had imagined ([#566]).
      *Still unexercised:* the fallback for firmware that clears its stats on
      finish. This U1 retained them, so the primary path ran.
- [x] **Three finished jobs, then print time stops being a guess.**
      **Already done, and this file did not know.** It said "Khayt still holds
      zero" from the day the item was written until 2026-08-26. Run against the
      shop's own store on that date, `lib/estimate-calibration.js` answers:

      ```
      { scope: "shop", gramsPerHour: 21.02, jobs: 19, spread: 0.25 }
      ```

      Nineteen jobs, not zero, the oldest dated **2026-07-18** — so the threshold
      was passed within days of the capture chain shipping in `3.6.0-beta.1`, and
      the estimator has been calibrated for over a month. Every one of the
      nineteen carries `actualsSource: {time: 'moonraker', weight: 'moonraker'}`;
      they are printer readings, not typed figures. The spread is 0.25 against a
      `MAX_RELATIVE_SPREAD` of 0.6, so the figure is not merely present, it is
      inside the tolerance the module itself requires before it will be used.

      For a sanity check against the one job this file did record by hand: the
      MiniDragon measured **18.6 g/h**, and the shop-wide median is 21.02 g/h.
      Same order of magnitude, and both a long way from the old assumed constant
      the calibration work found to be optimistic by roughly 3×.

      **How it went unnoticed is the part worth keeping.** Nothing was broken —
      the app captured every one of those jobs correctly. This file was reading a
      different signal, said zero, and nobody checked the claim against
      `calibrate()` because the claim was already written down. A roadmap that
      reports a solved problem as the headline blocker costs more than one that
      says nothing, because it is trusted.
      *Check it, do not assume it:* run `calibrate()` over `printLog` with
      `order-file-link`'s `allocateActuals`, and read `jobs` and `spread`.

      The MiniDragon job from 2026-08-24 is still unrecorded and still worth
      entering by hand — mark the order done and type **49.97 g / 2.69 h**. It is
      no longer the difference between calibrated and not; it is one more sample.

- [ ] **The 3.2-era hardware pass is still outstanding** — see
      [docs/PRELAUNCH-QA.md](./docs/PRELAUNCH-QA.md). Two items need hardware:
      the **printer camera** live image path, and carrier **API** shipping
      (manual shipping is fully working and tested).
- [ ] **R7 — SDCP resin printers.** Protocol layer built and tested
      ([#529](https://github.com/KhaytApp/Khayt/pull/529)); **socket layer built
      2026-08-24** — a WebSocket client whose socket is injected so every branch
      it takes is reachable from a test, UDP discovery, the poll branch, and a
      way to add one in the machine dialog. **Now blocked on hardware alone.**
      What is unproven is one step and worth stating precisely: whether a real
      mainboard answers the `M99999` broadcast and accepts the request frame. The
      broadcast itself was run against this LAN — binds, retransmits, times out
      clean, finds nothing, because there is nothing here to find.
      See [docs/KHAYT-COMPETITIVE-ROADMAP.md](./docs/KHAYT-COMPETITIVE-ROADMAP.md).

**Every printer protocol has now been audited against its vendor's own
documentation and firmware source twice** —
[docs/PRINTER-PROTOCOL-AUDIT.md](./docs/PRINTER-PROTOCOL-AUDIT.md).

The first run (2026-08-25, [#747]) found six defects, five of which had been
showing a wrong number indefinitely without ever throwing: a Duet stuck at 0%, a
Repetier that always looked idle, a PrusaLink with no filename, a Klipper
toolchanger reading the wrong nozzle, and — worst — OctoPrint recording the
slicer's own estimate as the measured weight, which fed
`estimate-calibration.js` its own guesses as evidence.

The second (2026-08-27, [#764]) found three more, in a blind spot the first run
had by construction: it audited what was INSIDE the payload, and never asked
which call a field is on, or what arrives when nothing arrives. Repetier was
still Idle / 0% on every machine; OctoPrint's 409 and Moonraker's 503 — both
ordinary, neither a fault — reached the shop as a raw `HTTP <status>`; and a
Repetier with no heated bed reported a bed at 0 °C, because `Number(null)` is 0.

Standing item, not a one-off. There is one printer on this bench and seven
protocols; for six of them the vendor's documentation *is* the test fixture, so
it needs re-running when a vendor ships a major firmware line. **Open and needing
hardware:** Bambu's poll is shaped for an X1 and used on a P1 — a fresh
connection and a `pushall` every 30 s, against documented guidance of no more
often than five minutes. The method and every source is in that file.

**Multi-shop is no longer deferred.** Organisations shipped in **3.5.0** (create
one, add branches, one passphrase for all) and **3.5.1** (*Across the branches* —
the cross-branch view). This file previously listed it as pending "the Cloud
decision"; that decision was made and shipped. What remains beyond it is the
wider Phase-3 HQ surface, still unscheduled —
[docs/MULTI-SHOP-CLOUD.md](./docs/MULTI-SHOP-CLOUD.md).

### Known gaps, deliberately not built

These are recorded so nobody assumes they exist:

| Gap | Why |
|-----|-----|
| **Telemetry transport** | ~~No endpoint exists.~~ **Built 2026-08-27** — `POST /v1/telemetry` in khayt-cloud (#25), both backends, and `lib/telemetry-sender.js` on this side. **Still dormant, and that is the gap now:** the ingest ships behind `telemetry_ingest`, off by default, so the flush 404s, keeps its queue and waits. It is the only write surface in the cloud that takes no credential — no shop, no account, just a consent box and a random install id — which is the design (telemetry gated on a cloud account would only ever describe cloud shops) and is why turning it on is a deliberate act after the deploy is verified. The 404 → 200 flip is the check. No desktop release is needed when it flips. |
| **Timelapse capture/encoding** | Needs ffmpeg + a real printer. `machine.webcam` carries the fields; no capture runs. |
| **Zapier / Make connectors** | External publishing artefacts, not code in this repo. |
| **Cloud-relayed public API**, remote-mobile PWA, cloud infra | Live in the separate `khayt-cloud` repo. |
| **Phase 3 — multi-shop HQ** | The organisation layer it was waiting on shipped in 3.5.0/3.5.1. The HQ surface on top of it is unscheduled, not blocked. |

## Shipped (3.3 → 3.6 — 2026-07 to 2026-08)

Four stable lines, nineteen beta releases and four release candidates since 3.2.0. Full detail per release is in
[CHANGELOG.md](./CHANGELOG.md); this is the index.

| Version | Date | What it was |
|---------|------|-------------|
| **3.7.0-beta.9** | 2026-08-27 | **The day the audit method left printers.** Every order imported from Salla had been recorded priced at **zero** since that integration shipped — `data.total` is not a field Salla sends, `Number(undefined)` is `NaN`, and the guard substituted 0, so revenue and margin were wrong on those orders and nothing ever threw ([#771], [docs/STOREFRONT-WEBHOOK-AUDIT.md](./docs/STOREFRONT-WEBHOOK-AUDIT.md)). Salla orders also stop all being titled "Salla: Order", and Zid is read whether or not its payload is wrapped. Plus job control for a Duet 3 with an SBC and for a password-protected Duet ([#767]) — both could be watched and never stopped — Repetier cancel and resume ([#768]), and camera auto-detect on any modern OctoPrint ([#769]). Windows + Linux only; macOS stays on beta.8 with a carried manifest. |
| **3.7.0-beta.8** | 2026-08-27 | **Installable designs, cost per model, and a second audit.** The four pieces of the modular design system — the CSS safety gate ([#758]), userData storage ([#759]), loading over IPC ([#760]) and the install/remove surface ([#761]) — which together are the first time a shop can install a design somebody else made; the machinery had existed for a long time and was never usable, because designs lived inside `app.asar`, read-only and replaced whole on every update. Analytics → Cost per model ([#763]) turns the measurements Khayt already takes into the one question a shop can act on: what a model is quoted at against what it actually costs. Also the LAN sweep that finds a printer which does not announce itself ([#757]) and the second protocol audit ([#764]). **Built for all three platforms**, ending the three-cut macOS drift that had left it on beta.5 since 2026-08-24. |
| **3.7.0-beta.7** | 2026-08-25 | **Medusa, both kinds of Duet, and what a design costs.** Medusa stores can send their orders to Khayt — and since Medusa has no webhook settings page, Khayt generates the subscriber rather than handing out a URL with nowhere to paste it ([#750]). A Duet 3 with an SBC becomes reachable at all: that build serves a completely different set of addresses and every request had been missing, so a supported configuration read as a switched-off printer — as did any Duet with a machine password, which had nowhere to be typed ([#752]). The Flow board marks orders late, which it never has: it borrowed the shared attention engine, misread the result two ways at once, and its own catch hid the throw, so a week-overdue job looked exactly like one due next month ([#753], [#754]). And the design picker says what each design hides or adds against the one in use ([#755]). Windows + Linux only; macOS stays on beta.5. |
| **3.7.0-beta.6** | 2026-08-25 | **The printers were answering; Khayt was not listening.** Every printer adapter audited against its manufacturer's own documentation and, where that was silent or wrong, that manufacturer's firmware source — six defects, five of them reporting a wrong number indefinitely without ever throwing, which is why none had been noticed. A Duet permanently at 0% with no filename (the `f` query flag filters out the very file the percentage needs). A Repetier that always read Idle (its reply is keyed by slug and was being indexed as an array). A PrusaLink with no filename (that endpoint has never carried one). A Klipper toolchanger showing a nozzle that was not printing. And OctoPrint recording the slicer's own estimate as the measured weight, which made every variance read as exactly zero and fed `estimate-calibration.js` its own guesses as evidence ([#747]). Also **R7** — Elegoo Mars/Saturn can be added and watched, found by network scan, still never tested against a real machine and the note says so ([#743]) — a measured job surviving app quit ([#742]), and a retried Salla/Zid order no longer becoming two ([#745]). Windows + Linux only; macOS stays on beta.5 with a carried manifest ([#748]). |
| **3.6.0** | 2026-08-21 | **The 3.6.0 line, released as stable.** Promoted from `v3.6.0-rc.4` with no code change between the two — the only commit `main` took after the tag was [#711], a status-doc fix. Khayt learns what prints actually cost: a model becomes a quote, the printer reports the real filament and duration on completion, and the estimator calibrates itself from finished jobs. It also opens the app outside the Gulf (tax added to a price rather than included in it, thirty country presets, documents in the shop's own language), closes four security holes including a portal link that exposed a whole message thread, and stops a restore-while-running from pushing old data over new. Supersedes v3.5.3. |
| **3.6.0-rc.4** | 2026-08-14 | **A restore can no longer overwrite newer data.** Restoring a backup, a restore point, or an imported file *while the app was running* could push that older copy to the cloud as the latest, and every other device would take it — silently, with the newer records gone. A restore is now treated like a fresh start: forget what the server was thought to hold, refetch, merge ([#708]). Also the organisation overview showing what each branch earned and is still owed, each in its own currency and never summed across them ([#707]), and a launch sync that asks only for what changed ([#705]). The current candidate ([#710]). |
| **3.6.0-rc.3** | 2026-08-14 | **Sync failures explain themselves.** A failed sync said "Sync error" and nothing else, forever ([#698]). Cut because thirteen commits had landed after rc.2 ([#704]). |
| **3.6.0-rc.2** | 2026-08-13 | **The copy buttons work.** rc.1 shipped with every "Copy link" button copying nothing ([#688]) — the reason a candidate is soaked rather than assumed. Cut to replace rc.1 ([#691]). |
| **3.6.0-rc.1** | 2026-08-12 | **The candidate for v3.6.0 stable**, and no behaviour change over `beta.19`. Cut because the promotion gate is real shop use and `beta.19` was 87 minutes old when promotion came up — so rather than assume a soak, the exact proposed code got a name, a mac build and a place on the pre-release channel where it can be installed and used on purpose. Stable stays on v3.5.3 ([#684]). |
| **3.6.0-beta.19** | 2026-08-12 | **Low stock follows the theme again.** beta.18 gave "low stock" its own colour token so recolouring it would not also recolour overdue jobs and spool age — right idea, wrong default: the token was a literal amber while every theme darkens its warning colour for the light appearance. Low stock rendered at 1.77–2.03:1 where the theme's own colour measured 4.71–5.93:1, on all seven light themes ([#680]). Found by running the app, not by a failing test. |
| **3.6.0-beta.18** | 2026-08-12 | **Cloud sync starts writing compressed** — 59 KB down to 9 KB on a real shop, the second half of the rollout beta.17 began; a second machine on beta.16 or earlier must be updated or it stops syncing ([#679]). Also documents that travel with a product, listed on the work order and — only if ticked to ship — the delivery note ([#678]); and marketplace fees in one click, including Etsy's two percentages *and* its 0.20 listing fee ([#677]). |
| **3.6.0-beta.17** | 2026-08-12 | **The release that opens the app outside the Gulf.** Sales tax added to a price rather than included in it, thirty country presets, and documents that print in the language the shop chose instead of that language and Arabic ([#664], [#666]). Also a security fix — a printer address written as a decimal integer could point Khayt at its own network ([#673]) — cloud backups readable when compressed, ahead of writing them, and a copy of the shop's data taken before any update touches it. |
| **3.6.0-beta.16** | 2026-08-10 | **Consumables reach the reorder list and purchase orders**, which until now only filament could. Plus a consumable PO no longer accused of being priced 1000× too high, receiving a filament PO records what it cost, and Electron 42.2.0 → 42.8.1. |
| **3.6.0-beta.15** | 2026-08-09 | A planned Bed Ready maintenance window no longer looks like a broken sync. |
| **3.6.0-beta.14** | 2026-08-09 | **Kits — several prints that are one object**, and they reach Bed Ready, the app whose users print things in parts ([#645], [#646], [#647]). A fee can now be a percentage rather than only a fixed amount — the groundwork marketplace fees later stood on. Also `.zip` straight into the print library ([#648]), consumable categories, and the last route that could read a message thread without proving the link. |
| **3.6.0-beta.13** | 2026-08-07 | **Anyone with a portal link could read the whole message thread on it.** Also: a re-sliced g-code file came back a stranger so its quotes never learned ([#632]), an "Identify" button for files Khayt cannot recognise ([#634]), 3MF recognition, and a print library that can live on a network drive or back up to object storage. |
| **3.6.0-beta.12** | 2026-08-06 | The filament library talked over itself and could strand a keyboard user ([#624]). "Slice for exact quote" gave a print time but no weight. |
| **3.6.0-beta.11** | 2026-08-04 | Signing in to the cloud could sit on "Connecting…" for half a minute and then fail; waiting for a verification code said nothing while you waited. |
| **3.6.0-beta.10** | 2026-08-04 | **A model you have printed before is priced from its own prints.** The estimate note stops stating the printer's rate as though it were measured. Also a printer reporting negative hours since its last service, and two empty Bed Ready sidebar headings. |
| **3.6.0-beta.9** | 2026-08-03 | **Security: the converter could be made to write a file anywhere the app could read.** Also packaging Bed Ready could leave the source checkout broken, a beta build could not find its own updates, and the shop's default infill was used to quote customers but not itself. |
| **3.6.0-beta.8** | 2026-08-03 | **A large 3MF could convert into a model missing most of itself**, and the converter stopped the app while it worked — that work now runs off the only thread the UI has. Plus HueForge FLAT mode, colour by region instead of by height. |
| **3.6.0-beta.7** | 2026-08-02 | **Two real files that did not work, and a feature nobody could find.** A 229 MB six-colour 3MF read as colourless because the member budget was spent on meshes before reaching the configs that identify it ([#571]). An update check on a local build showed a raw ENOENT instead of saying the build cannot self-update ([#572]). And the kanban the website advertises now opens by default in every theme rather than hiding behind a toggle ([#569], [#570]). Plus tests for solveHeightfield, the last large untested surface in the HueForge path ([#568]). |
| **3.6.0-beta.6** | 2026-08-02 | **A measured figure now names the job it was measured on.** Khayt keeps a completion offerable for a day; a shop starting its next print inside that window could be shown the previous job's figures wearing a green *Measured* label, with nothing to reveal it — and those figures train the estimator ([#566]). Also the first real-hardware fixtures for the completion capture ([#565]) and the U1 catalogue entry pinned to the machine ([#564]). |
| **3.6.0-beta.5** | 2026-08-02 | **Two Bed Ready print-quality fixes**, both found by diffing Khayt's colour plan against a 3MF the U1 was actually printing. The top colour band ended at the model's exact height, so the topmost layers belonged to no band and printed in the base colour ([#561]). And the opaque base printed at the same fine layer height as the colour bands — 57 layers where a real export used 28 ([#562]). |
| **3.6.0-beta.4** | 2026-08-01 | **Bed Ready input guards.** A layer height of `Infinity` was accepted and produced a stack of infinitely-tall colours; a thickness that was not a number would have poisoned every blend. Also the first tests for `lib/hueforge.js` — 434 lines, fifteen exports, previously none. The mesh itself proved correct ([#559]). |
| **3.6.0-beta.3** | 2026-08-01 | **What a live printer showed.** A five-hour job was displayed as 1% done with a 178-hour ETA — progress came from file position, not layers ([#557]). A Klipper machine could be configured as the wrong make and silently record nothing ([#556]). And the actuals reader met real hardware for the first time: every field correct. |
| **3.6.0-beta.2** | 2026-08-01 | **Quoting corrected, and honest about its limits.** A part's walls are derived from its surface rather than a flat share of its volume ([#551]) — a 100 mm part was being quoted at roughly double. Khayt now says outright when a shape is one it cannot price ([#553]), scored against a real slicer ([#552]). Carries the v3.5.3 lockout fix ([#548]), a Help menu ([#549]), and camera auto-detect that asks the printer ([#554]). |
| **3.6.0-beta.1** | 2026-07-31 | **Khayt learns what prints actually cost.** A model becomes a quote ([#531]), a customer can upload one and get a price ([#532]), the printer reports real filament and duration on completion ([#533]), the settings that worked are remembered against the file ([#534]), duplicate models are recognised ([#535]), a finished job is joined to the file that produced it ([#536]), and the estimator calibrates itself from finished jobs ([#537]). Also fixed two things that had never worked: 3MF files never gave up their slicer figures, and Bambu/Orca print times were silently dropped. Closes **R1–R6** of the competitive roadmap. |
| **3.5.3** | 2026-08-01 | **Security.** Every per-IP brute-force lockout in the LAN server was inert and had been since v2.2.5 — the counter reset on every attempt, so it never reached the limit. Cut from `release/3.5.x`, not `main`. ([#548]) |
| **3.5.2** | 2026-07-30 | Two customer-facing places that could name the wrong currency. |
| **3.5.1** | 2026-07-30 | *Across the branches* — the cross-branch view 3.5.0 described but did not include. |
| **3.5.0** | 2026-07-30 | **Organisations** — one passphrase for every branch. Plus an operator-lock recovery code that was being wiped off screen before it could be read. |
| **3.4.x** | 2026-07-29/30 | The 3.4.0 beta line released as stable, then two patches. |
| **3.3.0** | 2026-07-26 | The 3.3.0 beta line released as stable. |

[#529]: https://github.com/KhaytApp/Khayt/pull/529
[#531]: https://github.com/KhaytApp/Khayt/pull/531
[#532]: https://github.com/KhaytApp/Khayt/pull/532
[#533]: https://github.com/KhaytApp/Khayt/pull/533
[#534]: https://github.com/KhaytApp/Khayt/pull/534
[#535]: https://github.com/KhaytApp/Khayt/pull/535
[#536]: https://github.com/KhaytApp/Khayt/pull/536
[#537]: https://github.com/KhaytApp/Khayt/pull/537
[#548]: https://github.com/KhaytApp/Khayt/pull/548
[#735]: https://github.com/KhaytApp/Khayt/pull/735
[#736]: https://github.com/KhaytApp/Khayt/pull/736
[#742]: https://github.com/KhaytApp/Khayt/pull/742
[#743]: https://github.com/KhaytApp/Khayt/pull/743
[#745]: https://github.com/KhaytApp/Khayt/pull/745
[#747]: https://github.com/KhaytApp/Khayt/pull/747
[#748]: https://github.com/KhaytApp/Khayt/pull/748
[#750]: https://github.com/KhaytApp/Khayt/pull/750
[#751]: https://github.com/KhaytApp/Khayt/pull/751
[#752]: https://github.com/KhaytApp/Khayt/pull/752
[#753]: https://github.com/KhaytApp/Khayt/pull/753
[#754]: https://github.com/KhaytApp/Khayt/pull/754
[#755]: https://github.com/KhaytApp/Khayt/pull/755
[#756]: https://github.com/KhaytApp/Khayt/pull/756
[#757]: https://github.com/KhaytApp/Khayt/pull/757
[#758]: https://github.com/KhaytApp/Khayt/pull/758
[#759]: https://github.com/KhaytApp/Khayt/pull/759
[#760]: https://github.com/KhaytApp/Khayt/pull/760
[#761]: https://github.com/KhaytApp/Khayt/pull/761
[#763]: https://github.com/KhaytApp/Khayt/pull/763
[#764]: https://github.com/KhaytApp/Khayt/pull/764
[#765]: https://github.com/KhaytApp/Khayt/pull/765
[#767]: https://github.com/KhaytApp/Khayt/pull/767
[#768]: https://github.com/KhaytApp/Khayt/pull/768
[#769]: https://github.com/KhaytApp/Khayt/pull/769
[#771]: https://github.com/KhaytApp/Khayt/pull/771
[#772]: https://github.com/KhaytApp/Khayt/pull/772
[#774]: https://github.com/KhaytApp/Khayt/pull/774
[#775]: https://github.com/KhaytApp/Khayt/pull/775
[#776]: https://github.com/KhaytApp/Khayt/pull/776
[#777]: https://github.com/KhaytApp/Khayt/pull/777
[#778]: https://github.com/KhaytApp/Khayt/pull/778
[#549]: https://github.com/KhaytApp/Khayt/pull/549
[#551]: https://github.com/KhaytApp/Khayt/pull/551
[#552]: https://github.com/KhaytApp/Khayt/pull/552
[#553]: https://github.com/KhaytApp/Khayt/pull/553
[#554]: https://github.com/KhaytApp/Khayt/pull/554
[#556]: https://github.com/KhaytApp/Khayt/pull/556
[#557]: https://github.com/KhaytApp/Khayt/pull/557
[#559]: https://github.com/KhaytApp/Khayt/pull/559
[#561]: https://github.com/KhaytApp/Khayt/pull/561
[#562]: https://github.com/KhaytApp/Khayt/pull/562
[#564]: https://github.com/KhaytApp/Khayt/pull/564
[#565]: https://github.com/KhaytApp/Khayt/pull/565
[#566]: https://github.com/KhaytApp/Khayt/pull/566
[#568]: https://github.com/KhaytApp/Khayt/pull/568
[#569]: https://github.com/KhaytApp/Khayt/pull/569
[#570]: https://github.com/KhaytApp/Khayt/pull/570
[#571]: https://github.com/KhaytApp/Khayt/pull/571
[#572]: https://github.com/KhaytApp/Khayt/pull/572
[#624]: https://github.com/KhaytApp/Khayt/pull/624
[#632]: https://github.com/KhaytApp/Khayt/pull/632
[#634]: https://github.com/KhaytApp/Khayt/pull/634
[#645]: https://github.com/KhaytApp/Khayt/pull/645
[#646]: https://github.com/KhaytApp/Khayt/pull/646
[#647]: https://github.com/KhaytApp/Khayt/pull/647
[#648]: https://github.com/KhaytApp/Khayt/pull/648
[#664]: https://github.com/KhaytApp/Khayt/pull/664
[#666]: https://github.com/KhaytApp/Khayt/pull/666
[#673]: https://github.com/KhaytApp/Khayt/pull/673
[#677]: https://github.com/KhaytApp/Khayt/pull/677
[#678]: https://github.com/KhaytApp/Khayt/pull/678
[#679]: https://github.com/KhaytApp/Khayt/pull/679
[#680]: https://github.com/KhaytApp/Khayt/pull/680
[#684]: https://github.com/KhaytApp/Khayt/pull/684
[#688]: https://github.com/KhaytApp/Khayt/pull/688
[#691]: https://github.com/KhaytApp/Khayt/pull/691
[#698]: https://github.com/KhaytApp/Khayt/pull/698
[#704]: https://github.com/KhaytApp/Khayt/pull/704
[#705]: https://github.com/KhaytApp/Khayt/pull/705
[#707]: https://github.com/KhaytApp/Khayt/pull/707
[#708]: https://github.com/KhaytApp/Khayt/pull/708
[#710]: https://github.com/KhaytApp/Khayt/pull/710
[#711]: https://github.com/KhaytApp/Khayt/pull/711
[#722]: https://github.com/KhaytApp/Khayt/pull/722
[#723]: https://github.com/KhaytApp/Khayt/pull/723
[#725]: https://github.com/KhaytApp/Khayt/pull/725
[#727]: https://github.com/KhaytApp/Khayt/pull/727
[#728]: https://github.com/KhaytApp/Khayt/pull/728
[#729]: https://github.com/KhaytApp/Khayt/pull/729

## Shipped (3.2.0 beta line — 2026-07)

Every item below is on `main` with unit tests **and** a live Electron smoke wired into CI.

| Beta | Feature | Spec |
|------|---------|------|
| beta.11 | Maker-tools depth (print-file folders/tags/bulk import, M600 colour-swap, Orca-family install) | — |
| beta.12 | **QC / reprint / RMA** — inspection gate, defects, linked reprints, warranty | [QC](./docs/KHAYT-3.0-QC-SPEC.md) |
| beta.13 | **Printer catalog** + machine→calculator auto-fill + auto-priced catalog products | — |
| beta.14 | **Shipping & fulfillment** — Saudi carriers, manual-first, portal tracking | [SHIPPING](./docs/KHAYT-3.0-SHIPPING-SPEC.md) |
| beta.15 | **BOM / assembly** — components, cost rollup, stock deduction | [BOM](./docs/KHAYT-3.0-BOM-SPEC.md) |
| beta.16 | **Privacy / PDPL** — intake consent, DSAR export, erasure modes, retention | [PRIVACY](./docs/KHAYT-3.0-PRIVACY-COMPLIANCE-SPEC.md) |
| beta.17 | **Assembly tracking** — per-part QC, completion gate, per-part reprint | [BOM §5](./docs/KHAYT-3.0-BOM-SPEC.md) |
| beta.18 | **Public API** — scoped bearer tokens + versioned `/v1` | [PUBLIC-API §1](./docs/KHAYT-3.0-PUBLIC-API-SPEC.md) · [openapi.yaml](./docs/openapi.yaml) |
| beta.19 | **Webhook event bus** — subscriptions, fan-out, retry, delivery log | [PUBLIC-API §2](./docs/KHAYT-3.0-PUBLIC-API-SPEC.md) |
| beta.20 | **Telemetry** — opt-in, PII-free by construction (no transport yet) | [TELEMETRY](./docs/KHAYT-3.0-TELEMETRY-SPEC.md) |
| beta.21 | **Durable webhook retries** — survive an app restart | [PUBLIC-API §2](./docs/KHAYT-3.0-PUBLIC-API-SPEC.md) |
| beta.22 | **Printer cameras** — LAN-only, host-pinned snapshot proxy | [WEBCAM](./docs/KHAYT-3.0-WEBCAM-SPEC.md) |

**Already complete (verify before re-planning):** the Phase-0 sync foundation
(`renderer/sync.js` — change stamper, tombstones, delta extract) is implemented, wired
into the save choke point, and covered by tests. It was previously mis-recorded as a gap.

## Earlier

## Shipped (2.2.0 — 2026-05-30)

| Bundle | Theme | PR | Highlights |
|--------|--------|-----|------------|
| **A** | Production shop | [#49](https://github.com/khaytapp/Khayt/pull/49) | LAN printer polling (RFC1918), gift card checkout, WIP hard limits |
| **B** | ZATCA & email | [#50](https://github.com/khaytapp/Khayt/pull/50) | Auto-submit pipeline, submission log, custom SMTP |
| **C** | Customer portal | [#51](https://github.com/khaytapp/Khayt/pull/51) | LAN quote approval links, portal survey, share modal |
| **D** | Platform hardening | [#53](https://github.com/khaytapp/Khayt/pull/53) | E2E critical flows, ensure-electron, stale PR cleanup |

### Superseded / closed

| PR | Reason |
|----|--------|
| [#3](https://github.com/khaytapp/Khayt/pull/3) | Early sidebar shell; **Studio shell on `main`** replaced it. Close without merging. |
| [#11](https://github.com/khaytapp/Khayt/pull/11) | Lint scope; superseded by `npm run lint` / `npm run check` on `main`. |
| [#31](https://github.com/khaytapp/Khayt/pull/31) | `test/store-io.test.js` already on `main`; branch is an old refactor stack. |
| [#52](https://github.com/khaytapp/Khayt/pull/52) | Wrong Bundle D scope (daily ops). Replaced by platform-hardening branch. |
| [#59](https://github.com/khaytapp/Khayt/pull/59)–[#60](https://github.com/khaytapp/Khayt/pull/60) | Security scans consolidated in **v2.3.0** (`release-hardening`). |

## Completed (2.1.0 — 2026-05-30)

- [x] Document versioning (`VERSIONING.md`), lint, and test harness
- [x] Split `renderer/app.js` into feature modules (`app.js` is a thin entry shell)
- [x] Split `main.js` into `lib/store-io.js`, `lib/updater.js`, `lib/lan-server.js`, `lib/zatca-crypto.js`
- [x] Unit tests for pure logic (`npm test` — 120+ cases)
- [x] CSP hardening: drop `script-src 'unsafe-inline'` in Electron CSP
- [x] Locale files per language (`renderer/locales/*.js` + `npm run i18n:extract`)
- [x] E2E smoke test (`npm run test:e2e`)
- [x] Typed store contract validated on load (`lib/store-validate.js`)
- [x] LAN tunnel: confirm dialog + risk acknowledgement before `localtunnel`

## Versioning reminder

| Type | Example |
|------|---------|
| Patch (minor updates) | `2.1.0` → `2.1.1` |
| Minor (significant) | `2.1.0` → `2.2.0` |
| Major | `2.x.x` → `3.0.0` |

Details: [VERSIONING.md](./VERSIONING.md).
