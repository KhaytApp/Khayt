# Khayt for macOS — native

A native Mac app, replacing the Electron build **on macOS only**. Windows and
Linux stay on Electron: this exists because Electron cannot be made to feel like
a Mac app, not because the Electron app is going away.

## The architecture, and why

Khayt is ~97,000 lines of JavaScript. This does not rewrite all of it.

| | Lines | Here |
|---|---|---|
| Pure `lib/` — tax, pricing, payment plans, split-order, loyalty, estimator | 29,121 | **reused**, run in JavaScriptCore |
| `renderer/` — the interface | 52,855 | **rewritten** in SwiftUI. This is the point of the exercise |
| `main.js` — 192 IPC handlers | 5,904 | rewritten in Swift |
| Impure `lib/` — store-io, printer protocols, LAN server | 9,583 | rewritten in Swift |

**The business logic is not rewritten, and that is deliberate.** macOS ships
JavaScriptCore as a system framework, so those modules run here unchanged, with
nothing bundled and no Node. A Swift `computeTax` would earn the right to be
wrong in a second, different way, and every future fix would have to be made
twice — in an app whose whole recent history is money bugs found one at a time.

Proven, not assumed:

```
                Swift (JavaScriptCore)     Node              match
tax         →   347826.08 / 52173.92       same              ✓
instalments →   [666.67, 666.67, 666.66]   same              ✓
quote total →   187.5                      same              ✓
```

`MoneyParityTests` runs every case a review pass got wrong — the nil VAT return,
exclusive pricing, the instalment remainder, the split-order deposit, the
customer progress tracker — through both engines and compares the values.

## Layout

```
mac/
  KhaytCore/                     Swift package
    Sources/KhaytCore/           the JS bridge + typed money API
    Sources/KhaytCore/JS/        copies of lib/*.js  ← never edit; run mac/sync-js.sh
    Sources/KhaytApp/            the interface (SwiftUI) — reads, never writes
  sync-js.sh                     re-copy from lib/
  verify-safestorage.sh          confirm the Keychain link against a live store
```

## The copies are guarded twice

SPM resources must live inside the package, so `JS/` holds copies of `lib/`.
That is a fork waiting to happen, so:

* `test/mac-core-is-not-a-fork.test.js` — byte comparison, runs on Linux CI, free.
* `MoneyParityTests` — the same check *plus* Swift-vs-Node values. Needs macOS,
  so it is not in CI: a macOS runner bills at 10×, which is a decision rather
  than a detail. Run it locally before touching anything in `lib/`.

```bash
cd mac/KhaytCore && swift test
```

## Secrets

The store file is plain JSON; three fields inside it are not. The AI key, the
cloud token and the S3 secret are `__enc__` + base64 of Electron `safeStorage`,
which on macOS is Chromium's OSCrypt. `SafeStorage.swift` implements it, and the
shape was measured rather than assumed:

```
ai.apiKey            total 115  prefix "v10"  body 112  body % 16 == 0
cloud.token          total  83  prefix "v10"  body  80  body % 16 == 0
s3.secretAccessKey   total  35  prefix "v10"  body  32  body % 16 == 0
```

Swift and Node are held to identical bytes across the padding edges, and `seal`
refuses to return a field it cannot itself open — the failure it guards is
overwriting a working secret with bytes nothing can decrypt.

One link is deliberately not in the suite: that the Keychain item holds the
PBKDF2 password. Confirming it means reading a live secret, so it is a command
you run, not a test that runs itself:

```bash
./mac/verify-safestorage.sh          # dev store
./mac/verify-safestorage.sh Khayt    # packaged app
KEYCHAIN_WAIT=120 ./mac/verify-safestorage.sh    # slow to answer the prompt
```

It waits a minute for the Keychain and then gives up saying so. `security` blocks
on that permission prompt with no limit of its own, and the prompt can open
behind another window — or never, in a shell with no window server session (ssh,
CI, a git hook). If the password does not arrive, the script checks nothing and
says nothing about your store: an unanswered prompt used to be reported as every
secret failing to decrypt, which is a permission problem wearing the costume of a
corrupt store.

Two traps it will show you:

* **The Keychain item is named after `app.getName()`, which is not constant.**
  A dev run uses `khayt` (package.json `name`); a packaged build uses `Khayt`
  (electron-builder `productName`). Different items, different keys, different
  store files. Mixing them looks exactly like a corrupt store.
* **A native binary has a different code signature, so macOS treats it as a
  different application** and prompts before granting access to Electron's key.
  Expected, once per binary — but it means an unsigned debug build and the
  shipped app are two separate grants.

## The interface

```bash
./mac/make-app.sh --open      # build Khayt.app and launch it
cd mac/KhaytCore && swift run Khayt    # or the bare binary, for working on it
```

`make-app.sh` assembles a real, double-clickable application: the release binary,
the SwiftPM resource bundles, the Khayt icon, an `Info.plist`, and an ad-hoc
signature. `--install` puts a copy in `/Applications` as **Khayt Native.app**, so
it sits beside the Electron app rather than on top of it.

**It is not the shipping build.** Ad-hoc signing means this Mac will run it and no
other will; a Developer ID, a hardened runtime and notarisation are what make it
something a shop can download, and none of that exists yet.

**⌘R reloads from disk.** The store is read once, at launch, so anything the
Electron app writes after that is invisible here until asked for — and while this
is a reader, the two are expected to be open at the same time.

Two things the bundle changes:

* Its identifier is `app.khayt.mac`, **not** `app.khayt.hub`. Two applications
  sharing an identifier confuse Launch Services, the defaults domain, and the
  Keychain's idea of who is asking. It also means the bundled app and `swift run`
  remember their windows separately — `app.khayt.mac` against the bare `Khayt`
  domain — and each needs its own Keychain grant, since they are two signatures.
* `swift run` has to tell AppKit it is a windowed app, or the window opens behind
  everything. A bundle says so itself, so the app now asks only when it has no
  bundle identifier. An app that shoves itself in front of your work on every
  launch is one people learn to resent.

It can change a model's favourite star and file models into groups, and only
while it owns the book. Select several — click, ⌘-click, ⇧-click — and the whole
selection is filed in ONE write: seven kings filed one at a time would be seven
read-modify-writes and six windows in which a crash leaves the collection half
made.

Group names go through `lib/organise.js`, bundled and run rather than ported,
because the rule that matters is that a name matching one already in use IS that
name and adopts its spelling. "Saudi Kings" and "saudi kings" as two chips, each
holding part of one collection, is exactly what that module exists to prevent. See **Who owns the store**; the star is a control when this app holds
ownership and a plain mark when the Electron app does, because a disabled toggle
invites people to keep pressing it.

Three shelves off one sidebar: the pipeline as a real `Table` of jobs, the
customers derived from those jobs, and the print library as a grid of models with
the shop's groups beneath it. Each has an inspector. It opens on the shop's own
book if there is one, falling back to the sample only when there is not.

**Put `.inspector` on the `NavigationSplitView`, never inside `detail`.** Inside
it, the detail content is laid out against the window *minus the inspector* with
the sidebar's width never taken off — so a `Table` stretches its columns across
200pt it does not have, and the right-hand ones are clipped away rather than
compressed. The Owed column vanished twice that way before the cause was found,
and column `max` widths do not save you: the stretch ignores them.

It opens a store **read-only**, and there is no code in `KhaytApp` that writes — that is the constraint at the foot of this file
honoured rather than worked around.

A reader can still be wrong in the way that matters: showing a figure the app
the shop actually bills from disagrees with. So the money on screen is not
arithmetic written in Swift. The tax split in the inspector comes from
`lib/tax.js` through `KhaytEngine`, and the sidebar's stage order comes from
`lib/order-progress.js`. What the app works out for itself is what any table
works out — sort keys, filters, and `price - paid`.

Three books, and which one is open is stated in the toolbar and again at the
foot of the sidebar. Mistaking the sample for the shop's real position is the
one error this app must not allow.

| Source | Where |
|---|---|
| Sample shop | 42 jobs bundled in the app; subtitled *sample data — not a real shop* |
| This Mac — development | `~/Library/Application Support/khayt/khayt-store.json` |
| This Mac — Khayt | `~/Library/Application Support/Khayt/khayt-store.json` |

A store that is not on this Mac is not offered: a menu item that leads nowhere
is a dead end dressed up as a choice.

### Measuring a mesh

`Mesh.swift`. Triangle count, volume, bounding box — the three numbers
`geometryKey` is made of.

**Why not a slicer's code.** PrusaSlicer, OrcaSlicer, Snapmaker Orca and Bambu
Studio all descend from Slic3r and are **AGPL-3.0**. Linking any of them in
would put Khayt under the same licence, network clause and all. Spawning one is
arm's length and fine — `ModelInfo.swift` does exactly that, and it is kept as a
fallback for formats this does not read — but carrying one is not an option for
a commercial product.

The arithmetic was never the hard part. It is one cross product per triangle:
every triangle makes a tetrahedron with the origin, `a · (b × c) / 6` is its
signed volume, and on a closed mesh the outside faces cancel. What made the mesh
unreachable was the CONTAINER.

Three things worth knowing:

* **The STL formats are told apart by arithmetic, not by the word "solid".** An
  ASCII STL starts with `solid`, and so do plenty of binary ones, because the
  exporter wrote a name into the 80-byte header. A reader that sniffs for the
  word reads a binary file as text, finds no `vertex` lines and reports a model
  with **no triangles at all** — silently, because an empty mesh is a plausible
  answer. A binary STL is exactly `84 + 50n` bytes, and that is the test.
* **The volume is absolute at the end.** A mesh wound inside out gives the right
  magnitude with the wrong sign, and a negative volume in a library record is
  worse than an inverted mesh nobody noticed.
* **Nothing is resident.** A six-million-facet STL is 300 MB and is read fifty
  bytes at a time, in chunks that are a multiple of 50 so a facet is never split
  across two reads.

`MeshTests` knows its answers from arithmetic rather than from running the code
— a cube of side 10 is 1000 mm³ whatever any program says — and then checks the
whole thing against a real slicer, which computes the same quantity by the same
method and is therefore a genuine second opinion rather than a restatement. On
an odd off-origin box the two agree on the count exactly and on the volume to
within a thousandth of a percent, the difference being that the slicer
accumulates in `Float`.

`geometry-key.js` is bundled so the key this app writes is the key Khayt reads.
`model-identity.js` itself cannot be: its `contentHash` falls back to
`require('crypto')`, and both drift guards refuse a bundled module that names
Node — rightly, since a guarded require is still a require somebody will later
unguard. The pure half was split out for that reason and the whole half
re-exports it, so every existing caller is untouched.

### Adding a model

`LibraryImport.swift`, ⇧⌘I. The last piece: `Zip` opens the container, `Mesh`
measures it, `geometry-key` and `thumbnail-extract` turn that into the fields a
record carries, and this puts the file where Khayt puts it and writes the record
Khayt would have written.

The folder is `<root>/<PF-id>/` with the same `itemDirName` sanitising, and the
field names are `renderer/printfiles.js`'s exactly — `colors` not `colours`,
`favorite` not `favourite`, `thumbFile` not `thumb`. A record with one of those
wrong loads in both apps and shows a model with no colours and no picture, which
reads as a bad FILE rather than as a bad record and would survive a demo. So the
record is built by a function of its own and decoded straight back through
`LibraryFile` in the test — the type the grid actually uses.

That test immediately found one: `createdAt` is epoch milliseconds and
`updatedAt` is an **ISO string**, because the second is written by the store's
stamping and the first by whoever made the record. Both written as numbers, the
model showed no date at all.

The copy goes in before the duplicate check, because the check needs the hash
and the hash needs the bytes — and if the check refuses, the copy is taken back
out. A refusal leaves neither a record nor a file, and neither does a book that
will not accept the write. Both are tested, because a vault filling with files
no record points at is the failure nobody notices until the disk does.

`add` comes in two forms, and the second is not a convenience: addressed by path
rather than by `Shop`, it is the seam that lets the whole import run against a
throwaway store and a throwaway vault — a real file copied, really measured, a
real record written, and the book read back through `LibraryFile`. `StoreWriter`
splits itself the same way and for the same reason: an import whose only trial
run was on a shop's live library has not been tested, it has been risked.

`vaultFilename` keeps Arabic and drops separators, so nothing written can climb
out of the record's own folder, and a second file of the same name becomes
`part-2.stl` rather than overwriting the first — the case that matters, because
a print made of several parts puts them all in ONE folder.

### Reading a 3MF's mesh

`Mesh.measure3MF`. The model is XML inside the zip — `<vertex x= y= z=/>` then
`<triangle v1= v2= v3=/>` indexing into them — and on this shop's files that XML
is 436 MB uncompressed. It is streamed: inflated a megabyte at a time and
scanned as it arrives, so what is resident is the vertex table and nothing else.

**The build places the objects, and where they are placed is part of the
answer.** A Bambu/Orca 3MF keeps each object in its own `3D/Objects/*.model`
part, and the root lists them as `<item objectid= transform=>`. Measuring the
parts where they lie in their own files gives a box that is right about the
meshes and wrong about the model: on the Hulk helmet — twenty parts — that is
229 × 221 × 244 against the 1141 × 757 × 207 Khayt recorded, because the items
are placed hundreds of millimetres apart. The item's placement composes on top
of the component's, in that order; the other order rotates then translates along
the wrong axis, which on a symmetrical part is invisible.

The proof is `Mesh3MFTests.matchesKhaytsOwnKeys`: it measures every 3MF in this
Mac's library and compares against the `geometryKey` Khayt already wrote. Both
files match exactly, including `4295525:3487958.9:1141.57x757.09x207.37`. A key
made here and a key made there are the same key.

**Three bugs that test found**, all of which produce a plausible number rather
than an error:

* **The inflate stopped before the flush.** The decoder holds output of its own
  and has more to give after the last byte of input goes in; a loop that stopped
  at `src_size == 0` returned early and lost the tail — 8,912,896 bytes of a
  9,192,705-byte member. Caught by streaming a member out and comparing it with
  what went in, which is why `ZipStreamTests` exists separately from the mesh
  tests.
* **A tag name may be followed by a newline, or by `>`.** A slicer wrapping a
  long element onto several lines writes the first; `<mesh>` is the second. The
  reader accepted neither, so a wrapped part measured as nothing and the
  per-mesh reset never fired — the numbers came back byte-identical to the run
  before it was added, which is what gave it away.
* **Vertex indices are per mesh.** Accumulating them across objects makes each
  one after the first index into the previous object's vertices.

### Reading a 3MF — the part that cannot be shared

Adding a model to the library means reading two things out of a zip: the
embedded preview and the slicer's configs. Khayt does that with
`lib/zip-read.js`, whose own header says **"Pure Node (uses Buffer + zlib) —
main-process only"**. Neither exists in JavaScriptCore.

That is the whole reason library import has not landed here, and it is worth
being precise about, because it is narrower than "the bridge cannot carry a big
file". Checked module by module:

| | |
|---|---|
| `gcode-parse`, `print-file-parts` | already pure — usable today |
| `obj-parse` | already handles ArrayBuffer as well as Buffer |
| `mf-mesh` | Buffer in two helper lines; the rest is typed arrays |
| `zip-read`, `zip-intake` | need `zlib` — cannot be shared |
| `mf-convert` | Buffer throughout |

`Zip.swift` replaces the smallest of those. It reads the central directory from
the end of the file and seeks to a member rather than loading anything, and
`thumbnail-extract.js` still decides which preview wins and what the colours
are — the mechanics move, the rules do not.

**Every read is capped, and the number came from this shop's own files.**
`KING-Saud-ART-200mm-U1.3mf` is 46 MB on disk and its `3D/Objects/object_1.model`
member is **436 MB uncompressed**. A reader that inflates whatever it is pointed
at turns that file into 436 MB of memory, and a hostile one into as much as it
likes. The cap is checked against the size the directory claims, before a byte
is read, so an enormous member costs a comparison. The two things it is actually
for weigh 154 KB and 28 KB in the same archive.

Zip64 is refused rather than guessed at: a misread offset is a read of arbitrary
bytes, and no 3MF this opens is near 4 GB.

`ZipTests` builds its fixtures with `/usr/bin/zip` rather than checking one in —
the thing being tested is agreement with what other tools write, and a fixture
is only agreement with whatever wrote it once — and then runs the whole thing
against a real slicer's 3MF when one is on the machine, because
`/usr/bin/zip` and OrcaSlicer are not the same program.

### The one warm thing, and the one moving thing

Amber means exactly one state: a printer is laying down plastic right now. The
icon's drop of filament is that moment, and it is the only warm colour in the
mark. So it is the progress bar and the percentage on *Right now*, and the
Printing tile — and the tile is amber **only when the count is not zero**,
because a warm colour sitting on a zero says the opposite of what it means and a
dashboard where the warm colour is always on is one where it stops being seen.

There is exactly one piece of motion in the app: the printer symbol on that tile
cycles while something is printing. The HIG asks for motion that is purposeful
and brief and warns against adding it to anything frequent — a machine laying
down plastic is neither frequent nor decorative, and a shop glancing across the
room can tell from here that it is still going. It is off entirely under Reduce
Motion, and nothing is said by the movement alone: the symbol still turns amber
and the number still counts.

### Six months of takings

The dashboard was eight tiles and then two thirds of a window of nothing. Tiles
answer "what is it now"; none of them answers "is that good", which is the
question a shop opens this screen with.

`lib/forecast.js` is bundled and `KhaytEngine.revenueOutlook` calls it with the
same money function `renderer/analytics.js` uses, so the Mac's dashboard and
Khayt's analytics screen read the same numbers rather than two opinions about
revenue. `RevenueOutlookTests` compares the whole answer against Node.

The headline is a **sentence** — "Trending up — next month looks like 17,979
SAR, 78.3% above last." The HIG asks a chart to carry "brief descriptive text
that serves as a headline or summary … helping people grasp essential
information at a glance", and Weather's "Chance of light rain in the next hour"
is the model. There are three of them, because "your best month" and "up 8%" are
different news and a shop should be told the more interesting one. Hovering a
bar replaces the headline with that month's figure, in a fixed-height row so
the section cannot jump while it is being read.

**Not Swift Charts.** This is six bars; the framework's axes, marks and gesture
handling are a lot of machinery for a rounded rectangle scaled by a number — and
it draws nothing at all into the offline bitmap the snapshot runner uses, which
would make the one screen nobody could review the one that had just been
redesigned.

Two things it deliberately does:

* **Nothing at all when there is nothing to say.** `method == "none"` means too
  little history for a trend, and the section is absent rather than six flat
  zeros with a confident line across them. This shop's own book is in that state
  — nineteen jobs, every one priced at zero — so the chart correctly does not
  appear there.
* **Full colour at rest.** Written the other way first, everything muted until
  hovered, which made the resting state — the one anybody actually sees — the
  washed-out one. A chart is dimmed relative to the thing being pointed at, not
  relative to nothing.

Months are labelled from the module's `key` rather than its `label`: the module
answers `2026-08`, which is a sortable key and not a thing to show somebody, and
formatting from the key is what gets Arabic month names in Arabic.

### The colours, and where they came from

`Palette.swift`. Before it, every screen picked its own: `.orange` sat on a
printer alert, a sync retry and a lost-edits warning — three unrelated things
wearing one colour, which is the first thing the HIG's colour guidance says not
to do. They were also not Khayt's colours, and not contrast-checked; SwiftUI's
`.green` is 2.4:1 on white.

**Nothing in the palette was invented.** The app icon is a printed Arabic khaa
on a near-black ground: the letter and the diamond above it are cyan `#2BCDE4`,
and the one warm thing in the whole mark is the drop of filament leaving the
nozzle. So the app's colour is that cyan, and amber means exactly one thing —
something is being made right now. The status hues are
`renderer/themes/command/tokens.css` for light and `renderer/styles.css` for
dark, unchanged, so "done" is the same green in both of a shop's apps. Khayt's
light themes already darken those to clear WCAG AA on white and `styles.css`
says so in as many words; that work is taken rather than redone.

`PaletteTests` measures all of it — every colour, both appearances, against the
surface it actually sits on, at 4.5:1. `marked` (the favourite star) is the one
held to 3:1 instead, and only because it is never text: a gold dark enough for
4.5:1 on white is brown, and a brown star is not a star.

The app tints itself cyan **only when this Mac's owner has not chosen an accent
colour of their own**, because the HIG says a chosen accent replaces an app's.
An app with an asset catalog gets that free; this bundle is assembled by hand,
so `Khayt.appTint` asks. `AppleAccentColor` is absent for multicolour and 0–7
for a choice — and 0 is red, so reading it with `integer(forKey:)` would treat
"not set" as a deliberate choice of red and never apply the app's colour at all.

`PaletteTests.noRawColours` walks every source file and fails on a hue picked by
name. The palette only means anything if it is the only place colour comes from.

### Importing a library from the command line

The File menu takes files and folders, walks them, and shows a progress bar.
For three thousand models it is often easier to say so directly:

```bash
Khayt.app/Contents/MacOS/Khayt --import ~/Downloads/Models --dry-run
Khayt.app/Contents/MacOS/Khayt --import ~/Downloads/Models
```

`--dry-run` prints every file it would take and writes nothing — worth doing
first, because the import **MOVES**: the original is taken into the vault and is
no longer where you left it. `--keep-originals` copies instead.

It runs without opening a window: the parse happens in `main.swift` before
`KhaytApp.main()` is ever called, and the main actor's work is serviced by
pumping the run loop. A command that prints lines and exits should not steal
focus in the middle of somebody's work.

It takes the same store lock the window takes, and refuses by name if Khayt has
the book open — two processes writing the store is how a shop loses a day. The
loop itself is `LibraryImport.addMany`, shared with the menu, so the two cannot
drift on what counts as a model, what counts as a duplicate, or when an original
is removed.

`--previews` catches up a library that already exists instead of importing
anything, and needs no path:

```bash
Khayt.app/Contents/MacOS/Khayt --import --previews --dry-run
Khayt.app/Contents/MacOS/Khayt --import --previews
```

It draws a picture for an STL that has none — only a 3MF carries one its slicer
made — and records a measurement for one that was never measured. Either is
enough to bring a model in; a model that has both is left alone, so running it
twice costs nothing. Only STLs: a 3MF arrives with both, and nothing here reads
an OBJ's triangles yet.

Exit codes: `0` everything asked for arrived, `1` something failed (named on
stderr) or there was nothing to read, `2` no book / no library, `3` another app
holds the book, `64` the arguments did not parse.

### Photographing it

Judging a design by reading its source is guessing.

```bash
KHAYT_SNAPSHOT_DIR=/tmp/shots swift run Khayt     # writes 01-shop.png, then quits
```

It photographs the window's *theme frame* rather than its content view, because
a unified toolbar lives in the title bar — a sibling of the content, not a child
of it — and a picture without the toolbar is missing most of the chrome.

Two things the picture cannot show. Both are artefacts of drawing a window into
an offline bitmap, not faults to go and fix:

* **The sidebar comes out black and empty.** `NSVisualEffectView` draws nothing
  into a cached bitmap, and `.listStyle(.sidebar)` is one. To see those rows,
  run once with `.listStyle(.plain)`, which has no material.
The run also writes `*-paneN.png`, each scrolling pane photographed on its own,
for when the window shot leaves a doubt. It has the opposite blind spot — it
loses what a pane draws into its own layer, so thumbnails go missing there.

**A correction, since the wrong version stood here for a day.** The library
inspector once photographed as a solid black column and this file blamed the
capture, claiming that two `NSScrollView`s on screen meant one came back black.
That was not it. The inspector was attached inside `detail`, the content was laid
out against a width that never subtracted the sidebar, and the inspector had
nowhere to draw. Moving `.inspector` onto the `NavigationSplitView` fixed the
picture and the app at once. A capture limitation is a comfortable thing to
blame — check the layout first.
* `ImageRenderer` is not the way round it. It returns a "cannot render"
  placeholder for `NavigationSplitView`, `Table` and the toolbar alike — which
  is to say for everything that makes this a Mac window rather than a page.

**Sheets photograph without their words.** `cacheDisplay` asks each view to
draw itself, and SwiftUI does not draw itself: every `10-…`–`16-…` sheet shot
shows the AppKit-backed controls (fields, pickers, the default button) and none
of the labels around them. Rendering the layer tree instead was tried and gets
the same text back — none of it, upside down. So `SnapshotTests` renders the
same sheets through `ImageRenderer` as `20-…`–`24-…-words.png`, which shows the
words and blanks the controls. Between the two there is a picture of each.

The window frame is restored from the `Khayt` defaults domain, so `.defaultSize`
applies on a first run and never again. `defaults delete Khayt` to see what a
new shop sees. (That domain belongs to this binary; the Electron app's is
`app.khayt.hub`, and deleting one does not touch the other.)

## The invoice

⌘P on a job, or *Invoice* beside the money in the inspector. The document is
`lib/invoice-document.js` — the same four hundred lines the Electron window
prints — drawn in a `WKWebView` with `renderer/invoice.css`, which
`sync-js.sh` copies into `KhaytApp/Resources` beside the modules. Two
stylesheets would be two documents that agree until one is edited.

What is assembled in Swift, and why each piece is not in the module:

* **The money** — `Shop.taxSplit` applies the shop's inclusive-or-exclusive
  rule and the document is handed the answer, not the setting.
* **The ZATCA QR** — the TLV payload is `lib/zatca-qr.js`; only the pixels are
  CoreImage. A shop missing a required field gets the refusal printed in words
  rather than an empty box.
* **The PDF** — `printOperation(with:)`, not `createPDF`. `createPDF`
  photographs the view at whatever width the sheet happens to be, and the first
  export was one endless 480-point strip with the totals off the edge. Printing
  renders in print media — `@page { size: A4 }`, the margins — and MUST be run
  with `runModal(for:…)`: WebKit lays the pages out in the web process, and
  `run()` waits for them on the run loop they need. It hung a test for ten
  minutes before the documentation was read.

Two shared rules moved into the document while building this, because the Mac
had no copy of either and printed six invoices without them: the contact line
under the bill-to name (`contactLine`) and the printed date (`lib/print-date.js`,
which also now owns `LOCALE_TAGS`). Both default inside the module now, so a
host that forgets to pass them gets the right document rather than a blank.

## Settings

⌘, — five panes: Business, Invoice & Tax, Payments, Operations, Preferences.
Each pane is its own draft with its own Save, and a pane saves ONLY the keys
it shows. The rule is `lib/settings-edit.js`, lifted out of the 240-line
literal in `renderer/settings.js` and proven against it field for field over
3000 generated saves; its one deliberate difference — a key the form does not
carry keeps its value — is what lets the Business pane save a phone number
without zeroing the WIP limits it never displayed. Choosing a country for tax
rules goes through `chooseCountry`, the same rule Khayt's picker applies on
the change, so name, registration label, convention and rate land together.

`SettingsTests` round-trips every field of every pane through the rule and
reads it back: a form key the rule does not know leaves the stored value in
place, and that is the test that notices, for every field rather than a
sample. Two small tables are spelled out in Swift because the field list is
built while a view draws (`Shop.contentKey`, `Shop.languageNames`); both are
pinned to `lib/content-languages.js` by a test.

**The shop's name is `bizEn`/`bizAr`**, read through the shared fallback, not
`settings.shopName` — which nothing in Khayt writes. This app read `shopName`
for six weeks, fell back to the build's title, and would have issued this
shop's invoice from "Khayt". Found by opening the Business pane on the sample
and seeing every field empty.

## What the shop spent, and what it wasted

Two shelves under *Money*, each with a period menu, the search box wired to
what is actually on screen, and a form. The rules are `lib/expense-book.js`,
`lib/waste-entry.js` and `lib/date-range.js`, all lifted from renderer
handlers and proved against them; the app builds a form, hands it over, and
writes what comes back.

Logging a failed print writes **two collections in one swap** — the log and
the shelf — because a log saying a print wasted 200g while the spool still
holds them has told the shop it has filament it has already thrown away. The
spools the deduction touched are stamped and the ones it did not are left
alone: `rev` is what the cloud's sync baseline reads, so an unstamped edit
never leaves this Mac and a needlessly stamped one sends the whole shelf up.

`Shop.inPeriod` is the one shared rule this app spells out in Swift, because
it decides whether to draw a row and is asked once per record while a list
lays out — a bridge crossing each time would be thousands of them.
`SpendingTests` runs it against `lib/date-range.js` over every period, two
years of dates and four clocks. That parity run is what found the partial-date
case: the renderer's original filed a record dated "2026" under *this year*
and nowhere else, because `"2026".slice(0, 4)` is the year. The shared rule
now refuses a date that is not `YYYY-MM-DD`, which is what both apps say.

**Two toolbar findings, both only visible in a photograph.** A `Picker` in a
toolbar draws as a popup labelled with its selected value and came out
completely empty — a chevron with nothing beside it — in every style and
sizing tried; a `Menu` with a bare `Text` label works. And a toolbar `Menu`
draws a `Label` as its icon alone, which `.labelStyle(.titleAndIcon)` does not
change.

## Every print pays for its filament

A print takes its filament off the shelf whatever the result, and it takes what
it ACTUALLY used.

**A failed print deducts.** `lib/qc-failure.js` draws the wasted grams off the
spools the job was printing from — the same claims a completion would settle,
in the same proportions — and records which spool on the waste row so a host
that lets a shop undo the failure can put them back. The job is NOT marked
`materialDeducted`: it is not done, and the reprint still deducts its own. So a
job that fails once and then succeeds costs the shelf both attempts, which is
what actually left the spool.

**The amount can come from the printer.** A print that stopped at 40% did not
use what it was quoted, and the printer is the only thing that knows how far it
got. `deductForOrder` takes an optional `actualGrams` and scales every part's
claim by it, so each spool is still charged its own share rather than one lump
coming off the first one. Absent — which is every job Khayt has ever deducted
for — the estimate stands exactly as before.

`printerActuals.measuredSoFar` is what a failure asks. It is deliberately NOT
`prefillActuals`: that falls back to the estimate, which is right for a
completion and exactly wrong for a failure, where offering the whole-job figure
as the default invites a shop to confirm a number that is certainly too big.
Measured grams or nothing. Only Moonraker and Duet report cumulative extrusion;
OctoPrint, PrusaLink and Bambu report time and a slicer prediction dressed as a
measurement, which `lib/printer-actuals.js` explains at length and refuses.

**Waste logged against a job deducts too**, off that job's spools rather than
off the first spool of the material — which is what a material lookup does, and
it charges the wrong roll when a shop has two of the same filament. The entry
records `drawn`: which spool and how much off each, so deleting it puts back
exactly what it took. That matters when the assigned spool ran out and the rest
spilled onto a sibling; a row that remembered only "which spool" would put the
whole lot back on one. Rows written before `drawn` still restore the old way.

**Grams the spool switch already took are not charged again.** Switching spools
mid-print deducts there and then and records the amount on the part; the weight
a shop types for a failed print is the WHOLE print, so the switch's grams come
off that figure before it is drawn. Without it a job that switched 50 g and
failed at 120 g takes 120 more off the shelf — 170 charged for 120 used.

**On the Mac the figure is typed**, because reading it needs the poller, which
lives in Khayt. The sheet says so, and says the grams come off the shelf.

**The bridge had to change.** `recordQcFailure` returned the order and the
waste row and dropped the inventory — the rule mutates the array it is handed,
which is a copy on the Swift side, so the deduction would have happened inside
JavaScriptCore and been thrown away. The shelf comes back now, and is written
in the same swap.

## Telling the customer

A move that would reach outside the shop is refused whole — a job cannot be
half-finished, with the book updated and nobody told. **Telegram is the one
exception now**, because this app can send it: the message is
`lib/telegram-message.js` (lifted from `renderer/integrations.js` and proved
against it over 3,000 generated moves) and the sending is `URLSession`.

That removes a real blocker rather than adding a feature. A shop whose only
integration is a Telegram bot — which is most small shops — could not finish a
job on the Mac at all.

Three things about how it is sent. It goes **after** the write and only if the
write succeeded, because a message about a job that was not saved is worse than
no message. It is **awaited**, not fired and forgotten: the whole reason these
moves were refused is that a piece of the move would silently not happen, and a
send nobody looks at puts the app back there. And a failure is **said out loud**
and is not fatal — the job is finished, the book says so, and undoing a correct
write because a message did not go out is the wrong trade; the shop is told, and
can send it by hand.

Webhooks, email and the portal are still refused. The webhook bus has
subscriptions, a delivery log, retries with backoff that survive a quit, and a
410-Gone rule; doing that badly means a shop's ERP counting a job twice, which
is a real invoice. Refusing is the honest answer until it is done properly.

**The chat id is fixed.** Khayt stripped every chat id with `[^0-9@-]`, which
keeps the `@` and throws the name away — so a shop that typed `@khaytshop` was
sending to `@`, getting a 400 back, and being told nothing, for as long as the
feature had existed. `chatId` now recognises the two shapes Telegram documents
(a numeric id, negative for a group; a public `@username` of 5–32 letters,
digits and underscores) and REFUSES anything else rather than mangling it: a
refusal a shop can see beats a silent send to nowhere. The settings page
refuses a bad one at the point it is typed, the Electron main process refuses
before sending, and this app refuses before the request is built.

## A day in the shop

`DayInTheShopTests` asks the question the whole project is for: can a shop get
through a day without opening Khayt? One book, one file, the same calls the
screens make — take a job, price it, move it along the floor, fail an
inspection, print again, finish, hand over, take the money, print the invoice,
record what the day cost, put a spool right — and read the file back at the
end. A book where every write is correct on its own and the collections
disagree with each other is exactly the failure a shop finds at the end of a
month, and no single-write test can see it.

**It found one thing, and it is now fixed.** A QC failure used to write a waste
row with the grams and their cost and leave the inventory alone — so the
filament a failed attempt burned through never left the shelf, and a shop's
stock read high by the grams of every failure it had ever had. A failed print
now deducts, off the same spools a completion would have used, in the same
proportions. See *Every print pays for its filament*.

## The floor

＋ adds a printer, ⌘-click or double-click its name to correct one. The record
and what picking a model fills in are `lib/machine-edit.js`.

**An honest note on that lift.** The Electron machine editor mutates a draft
through thirty separate event handlers, so most of it is not a function that
can be copied and run beside a module. What IS lifted verbatim, and compared
over every printer in the catalogue, is `fillSpecs` — the piece where the
decisions are, including both rules it carries in capitals: the nozzle MATERIAL
is the point of the catalogue knowing it (an X1C ships hardened steel and an
MK4S ships brass, a ten-fold difference in expected life), and a threshold the
shop has typed is NEVER rewritten, because the app cannot tell a default from a
decision. The rest is a new rule assembled from those handlers and tested on
its behaviour; said plainly, because a weak guarantee described as a strong one
is worse than a weak one nobody relied on.

**What the sheet deliberately does not offer:** the printer's API, its webcam
and its downtime blocks. Those belong with the polling this app does not do
yet, and a screen that writes connection settings it cannot test is worse than
one that does not offer them. `MachineTests` asserts an edit made here carries
all three through untouched.

Two things this found. `printer-facts.js` has to be bundled BEFORE
`printer-catalog.js`: the catalogue reaches it through a global and falls back
to nothing, so without it every printer came back with no nozzle material and
no hotend limit — it does not raise, it just knows less. And the nozzle
fitments are read from `lib/nozzle-wear-data.js` rather than listed in Swift,
because a hand-written list said "steel" where the data says "stainless", the
sample shop's U1 matched nothing, and the picker photographed blank. That also
turned up a bad value in the sample itself — "hardened steel", which the wear
data does not know — so its X1C had a maintenance threshold worked out from the
wrong life.

## The shelf

⌘-click or double-click a spool to correct it, ＋ to add one. The record and
the correction are `lib/spool-edit.js`, lifted from `addInventoryItem` and the
spool editor's `onSave` and proved against both. What the rule settles: a blank
optional field is ABSENT rather than empty; a spool weighs at least a gram (one
weighing nothing divides into every cost-per-gram in the app); zero for a print
temperature means "not set", not "print at zero"; **an edit changes only what
it was given**, which is what lets a smaller editor exist without wiping the
fields it never showed; and a COST CHANGE IS REMEMBERED, because "what did this
material cost last time" is the question a shop asks when a supplier's invoice
looks wrong.

Two things come back from an edit: the spool, and the settings — the shop's
colour library is a setting, and naming a variant adds to it. They are written
in one swap, or the next editor offers a list that has forgotten what was just
typed. An edit is stamped; a new record is not.

Deleting is undoable through its own path: `registerMoveUndo` restores fields
onto records that are still there, and a deleted spool is not one — it would
take its price history and its usage with it, and nothing else in the book can
reconstruct them.

## The shop's daily backup

A shop running only this app had none at all — one disk failure from losing its
book. Khayt writes one a day into `Application Support/<build>/backups/` and
keeps the most recent thirty; this writes the same file, in the same place,
with the same name and the same rotation, so between them the two apps keep ONE
set of backups rather than two that each know half the days.

**The file is a copy of the store, byte for byte.** Khayt builds its backup by
re-encrypting the store it holds in memory, because the renderer holds those
thirty fields decrypted. This app never decrypts — the secrets on disk are
already `__enc__` — so copying the file produces exactly the artifact Khayt's
own restore expects, and does it without ever holding a shop's credentials in
memory. Verified against the real book: 981,152 bytes, `cmp`-identical.

Taken once a day, when the book is opened, and only by the app that owns it.
A failure is said in the sidebar and does not stop the book opening — a backup
that could not be written is worth knowing about, and is not a reason to refuse
to open the thing it was protecting. The sidebar carries the date of the last
one, so a shop can answer "when was this last backed up" by looking rather than
by trusting.

The Book menu carries **Back Up Now** and **Reveal Backups**. On demand writes
a SECOND file for the day, stamped with the time, rather than overwriting: the
automatic copy was taken before whatever the shop did this morning, and a shop
asking for one now wants both sides of that. A time-stamped file is not a day,
so it never becomes the answer to "when was the last backup".

There is deliberately **no export-to-share yet**. A copy of the store carries
the shop's credentials encrypted-at-rest, which is right for a backup and wrong
for a file somebody emails an accountant; Khayt redacts for that, through
`renderer/store.js`, and that redaction has not been lifted. Doing it hastily is
how credentials leak, so the menu offers the backup and not the export.

**Two bugs came out of building it.** `lib/upgrade-backup.js` declared a
top-level `const api`, which is harmless in a browser and fatal in the ONE
JavaScriptCore context every module shares — the second module to declare it
kills the runtime, silently, exactly as in *Profit and loss* above. It and
`lib/store-secret-paths.js` are wrapped now, and
`test/bundled-modules-are-wrapped.test.js` refuses the next one. And rotation
protected only `pre-upgrade-` backups while `lib/updater.js` writes
`pre-update-` ones: those survived by accident of lexicographic sort order
rather than by rule, and still cost a shop backups by counting toward the
thirty. Both prefixes are protected now.

## What the shop is owed

The other half of the Reports screen. `lib/receivables.js` is the aged
receivables computation, lifted out of `renderAgedReceivables` where it was
inline — so this app could show what a shop was owed in TOTAL and not who, or
since when, which is the half it acts on.

Three rules, each of which was a decision in the original. A VOIDED invoice is
not a receivable — dunning a customer for a cancelled invoice is the worst
thing this screen could cause. An order on an INSTALMENT PLAN is aged by each
unpaid instalment's own due date, not the order's: a plan agreed in January
with a payment due in August is seventeen days overdue in September, not eight
months. And the amount is `orderOwedBase` — price less credit notes less what
has been paid, in the shop's own currency — so a foreign order is comparable.

Rows come oldest first, because what a shop chases is the top of the list, and
the four ages sit across the top because "how much of this is really old" is
the question a total cannot answer.

The customer's name goes through `KhaytContentLanguages.read`, not
`nameEn || nameAr` — which the repo's own guard caught on the first run, and
which would have been blank for a shop that writes Turkish. The name is the
only thing on that row a person can act on.

## Profit and loss

The shop's quarters, from `lib/pnl-report.js`'s `pnlByPeriod` — lifted out of
the Electron analytics screen, where the whole aggregation was inline. A table
rather than a chart: this is the screen a shop reads at the end of a quarter to
decide something, and a bar it cannot read a figure off is decoration.

What the rule settles, each of which was a comment on the original: a VOIDED
invoice is not revenue and not VAT collected (voiding keeps `status:
'completed'` and only sets `voidedAt`); revenue is the price less credit notes,
in the shop's own currency; VAT is `computeTax(...).taxTotal`, which extracts
under inclusive pricing and ADDS under exclusive, rather than tax pulled out of
the revenue; and the fixed overhead is charged to EVERY quarter with activity,
pro-rated for the one in progress.

**The engine failing was silent, and a photograph is what caught it.** Bundling
`pnl-report.js` — whose file is named for what it produces rather than for the
`KhaytPnl` global it assigns — made the loader's own check throw, `Shop.load`
swallowed it with `try?`, and every screen carried on with no words (the
catalogue is loaded through the runtime, so every label rendered as its own
key), no tax, no reports and no writes. `Shop.engineProblem` now says so in the
sidebar, `EngineStartTests` asserts the runtime starts and that a handful of
labels are not their own keys, and the loader's exception list has a comment
saying a NEW module should be named for its global instead.

## What a job costs

`lib/calculator-cost.js` adds up six things: material, machine wear,
electricity, labour, any extra materials, and an allowance for prints that
fail. It is the same function the Electron calculator and the phone's quote
endpoint call.

It also returns a number whether or not you gave it those six. That is the
trap, and this app fell into it: `costOfPart` read wear, power, labour and the
failure rate from `settings.defaultWearRate` and four siblings — **five keys
Khayt has never written anywhere**. The fallback branch was the only branch,
every rate came out zero, and a job taken here was quoted at its filament and
nothing else. On this shop's own 272-gram, 14.9-hour job: **20.40 against the
109.43** the calculator quotes for the same work.

The rates live in `lib/print-rates.js` now, and they are not invented there —
they are the `value="…"` attributes the calculator's own form has shipped
since the first release, which is what a shop that has never touched those
fields is charged at. `test/print-rates.test.js` reads those attributes out of
`renderer/index.html` and requires them to match, because drifting apart
quietly is the only failure that module can have.

Order of precedence, the same as `applyMachineToCalculator`: Khayt's defaults,
then a saved printer preset, then the MACHINE for the two rates a printer
knows about itself — its power draw and its wear. Anything typed on the part
beats all of it, so a zero somebody meant stays zero.

**And the rates travel with the part.** `renderer/build.js` loads a part into
its editor with `$('#wearRate').value = part.wearRate || ''` and saves with
`clampPositive(...)`, so a part with no rates on it opens in Khayt with every
rate field blank and re-costs to nothing on the next save. A job taken here
would have lost its price on somebody else's machine. `costPart` returns the
figure, the four buckets and the seven rates from ONE crossing — made from the
same merged object, so what is written down is what was charged rather than a
second guess at it.

The New Job sheet shows the four buckets under the total. Not decoration: this
screen asks for grams and hours and nothing else, so most of what a print costs
is invisible unless it is said out loud — and a bucket reading nought is
exactly what nobody noticed for as long as this was broken.

## The cloud

Two operations, and the line between them is the design.

**Check** (`CloudReader`, `CloudCompare`) pulls `GET /v1/shops/{id}/store`,
unwraps the data key from the shop's own keyset with scrypt, opens the base with
AES-GCM, folds the delta chain through `KhaytSync.applyDeltas` — the same rule
the desktop folds with — and counts the difference. It writes nothing.

**Send** (`CloudWriter`, `lib/cloud-outbox.js`) appends to the chain with
`POST /v1/shops/{id}/deltas`. Three things make it safe, and each of them is
load-bearing:

* **It never puts a whole store.** `PUT /store` uploads a book and compacts the
  chain behind it. From the desktop that is safe, because the desktop merges
  what it pulled before it pushes. This app does not merge, so its "whole store"
  would be this Mac's book *and nothing else* — and the server would take it,
  because `baseRev` guards against a concurrent write, not against an incomplete
  one. `POST /deltas` can only ever add.
* **It sends one direction only.** `changesToSend` ships a record the cloud has
  never seen, or one whose local `rev` is *strictly higher*. A record that is
  newer in the cloud is one this Mac is behind on, and the only safe thing to do
  with it is nothing. This is where it differs from the desktop's
  `changesSincePush`, which measures against a cursor — right for a process that
  pushes on every save, wrong for an app that opens, pulls once and offers.
* **It pulls again immediately before sending**, and `baseRev` is that pull's
  revision. Anything that arrived between the check and the button is then a
  409, and a 409 refuses.

What it cannot send is a **settings** change: settings are one object rather
than revisioned records, so a delta has nowhere to put them. `Outbox` reports
that as `settingsDiffer` and the sheet says so, rather than dropping it quietly.

Both routes send `x-delta-capable: 1`, from one shared request builder. That is
not a courtesy: khayt-cloud records the capability of every credential it hears
from and the gate is unanimous — one `delta_capable = 0` row closes delta sync
for the whole shop, and every device falls back to uploading the entire store on
each save. Leaving it off the send path would also defeat the send, since
`recordDeviceCap` runs before `shopTakesDeltas`.

`SyncCrypto.seal` is pinned against Node in `SealTests`: the blob this app
produces is opened by `lib/sync-crypto.js` itself — the exact code every desktop
copy will use to read it — Arabic and all. macOS has no gzip, only raw DEFLATE,
so the container is written by hand and checked from the other side rather than
against itself.

### When the shop's chain is closed

khayt-cloud will not take a delta chain for a shop unless it is sure every
credential can read one. `deltaGateOpen` refuses on a device recorded as
blob-only, and also on **any live token nobody has been seen using** — and a
token with no expiry is live for ever, so one unused credential shuts the gate
permanently. `POST /deltas` then answers 404, which is the documented "this
server does not take deltas".

This shop's gate is shut. Found by running the send against the live service:
the pull, the decrypt, the fold and the outbox were all right, and the append
was refused.

So `sendToCloud` falls back the way the desktop does — **merge the cloud into
this book, then replace the cloud with this book** — and the order is the whole
safety argument. After the merge this book is a superset of what the cloud held
at `baseRev`, so replacing it loses nothing; anything that arrived in between
earns a 409 from that same `baseRev` and nothing is written. The two halves are
one function so they cannot drift apart, `sendWholeStore` takes the merge
report as an argument it does not use so the call cannot be written without
naming it, and the screen says "the whole book was sent" rather than "one
change", because they are different events.

### Bringing it down

`pullFromCloud` is the only thing this app does that rewrites records the shop
did not touch, and four things make it safe rather than the intention to be
careful:

* **A backup first.** The app already knows how; this is the operation that
  most wants one.
* **The read is inside the write.** `StoreWriter.update`'s async form reads the
  book, hands it to the merge, re-checks ownership and swaps — so a merge
  computed from a copy that went stale cannot put the stale copy back. The
  engine is an actor, so the window is a JavaScript call wide, which is why the
  second ownership check is the last thing before the swap.
* **Nothing is stamped.** A merged record keeps the CLOUD's `rev`. Bumping it
  would make this Mac look like it had edited every record it received, and it
  would push them all straight back on the next send.
* **`settings.cloud` is left alone.** The desktop's `viewSafeForLocal` decides
  whether its cached server view still holds, and a merge only moves the book
  FORWARD — so the view stays valid and this app never reaches into another
  app's bookkeeping.

The rule is `lib/cloud-inbox.js`, which is the desktop's own `pullMerge`.
Settings never come down; the ledgers are added to and never overwritten; a
local edit discarded because the record was deleted elsewhere is REPORTED, on
screen, rather than swallowed.

`CloudMergeTests` runs all of it against a copy of this Mac's real book in a
temp directory, ownership included as a closure so the refusal is exercised
too. Made the merge return the local store untouched and twelve assertions
failed.

## Not yet built

The rest of analytics, the cloud portal, the LAN server, and three of the six
printer protocols — `bambu`, `duet` and `repetier`. `KhaytCore` came first
because the alternative, screens against a half-trusted engine, is how the two
apps come to disagree about a shop's money.

THE PARAGRAPH ABOVE IS THE LIST, and `NotYetBuiltTests` reads exactly it — the
first paragraph of this section and nothing after it. That is the guard, and it
exists because this list had been wrong for months: it named gift cards, the
portfolio, the colour studio and the converter long after all four shipped, and
this is the section a person reads to decide what to build next. A list of work
that is already done is worse than no list, because it is believed.

**Analytics is the one with real distance left in it.**
`renderer/analytics.js` draws thirty-nine charts and tables — cash flow, cycle
time, client LTV, machine P&L, a throughput heatmap, a quote funnel, aged
receivables. `Reports.swift` draws the quarters, the best sellers, what is owed
and the totals. What is here is the money itself; what is missing is most of
the ways of looking at it.

**The protocols are counted against the six a machine can actually be set to** —
`renderer/machines.js` offers seven options and one of them is `none`.
`PrinterWatch.spoken` is the Mac's three: Moonraker, OctoPrint, PrusaLink.

Six things this list used to name are done. **Gift cards**, **the portfolio**
and **the colour studio** are shelves in the sidebar. **The converter** is
`Converter.swift`, reached from a model's own actions and from the File menu.
**Merging** what the cloud holds a newer copy of is no longer Electron's alone —
`lib/cloud-inbox.js` is the same fold, and `Check the cloud` brings a chain
down. And the **delivery promise** a storefront quotes from is published from
here now; see below.

### Opening a model in the shop's slicer

The library's *Open* handed the file to `NSWorkspace`, which gives it to
whatever macOS has registered for the extension — for a `.3mf` as likely a
viewer as the thing the shop prints from. This shop has four slicers installed
and has already told Khayt which it means, so the menu now offers that one by
name, with the rest behind *Open in*.

`lib/slicers.js` is bundled: the list, the default, and `isAllowedSlicerBinary`.

**The path is not trusted, even though it is in the settings.**
`settings.slicers[]` arrives in a restored backup and through cloud sync, so the
executable named there was chosen by whoever wrote that book, and the `args`
template beside it too. The allowlist — the program's name has to look like a
slicer — is *asked* before every launch rather than assumed from the entry
existing. That distinction is not academic: the Electron app carried the same
rule for months and called it from nowhere, using a denylist of interpreter
names instead, so `awk`, `find`, `xargs`, `make`, `git` and `busybox` were all
accepted as slicers. Fixed in the same change.

**It launches the bundle, not the binary.** The stored path points inside the
`.app` because that is what a slicer wants on a command line; running it that
way gives a second, dockless copy of an app the shop may already have open.
`appBundle(containing:)` walks up to the **outermost** `.app` — the first one
found going up is a helper the slicer ships inside itself, and launching an
updater instead of the slicer would have reported success.

### Syncing without being asked

Khayt pushes to the cloud at the end of every save — `renderer/app-state.js`
calls `KhaytCloudSync.scheduleSync()`, debounced so a burst of edits becomes one
upload. This app pushed only when somebody opened *Check the cloud* and pressed
*Send*, twice. So an edit made here stayed here, and the sidebar said "Not
synced automatically" in small grey type in the hope that somebody read it.

`AutoSync.swift` holds the scheduling; `Shop` runs it. The numbers are Khayt's
own — 2.5s debounce, 5s backoff doubling to a 5-minute ceiling — so two machines
in one shop behave the same way under the same load.

**The trigger is one hook, not twenty-one calls.** Twenty-one places in `Shop`
change the book. Rather than teach each of them to say so — and the
twenty-second somebody adds next month — `StoreWriter.didWrite` fires from
inside `atomicWrite`, which is where every write actually lands, from both the
synchronous and the async `update`. It fires only after the swap succeeds: a
refused write changed nothing and must not schedule a push of something that is
not there. `AutoSyncTests` proves both, and deleting the one line in
`atomicWrite` fails it.

**The data key now lives as long as the app.** It used to be dropped in the
sheet's `onDisappear`, which was right while the only thing that could use it
was the button on that sheet. A background push cannot stop to ask for a
passphrase. This is Khayt's own posture, not a loosening of it — the desktop
configures its sync controller "after unlock" and keeps the backend for the
session — and the PASSPHRASE is still never stored: this is the unwrapped key,
in memory, dropped on quit or from *Lock Khayt Cloud* in the menu bar. Earning
it again costs a scrypt at N=32768, most of a minute, which is why it is kept
at all.

**Three conditions, each a different silence.** Cloud connected, key unlocked,
and this Mac owns the book. The last one matters: this app often opens a book
Khayt owns, read-only, and the whole-book push merges the cloud in before
uploading — which needs the lock. The app that holds it is syncing anyway. All
three are `AutoSync.shouldSyncOnWrite`, pulled out of the early return they used
to be so they can be pinned; an early return that answers "no" for the wrong
reason is this feature's worst failure, because nothing happens and nothing is
said.

**The expensive path has a floor.** This shop's delta chain is closed, so every
push is the whole store: a backup, a merge, a rewrite of the book, a megabyte on
the wire. At the debounce that would be a day of typing turned into a hundred
full uploads. Deltas keep the fast cadence; whole-book pushes wait fifteen
minutes between them — short enough that a second machine is never further
behind than that.

It also pushes a book it is about to write to, and that terminates: the merge is
a write, the listener hears it, but `bookChanged` sees the sync in flight and
only queues one follow-up, which finds an empty outbox and sends nothing.

A 409 needs no special handling. `sendToCloud` begins with a fresh pull, so the
backoff retry measures against the head the cloud actually has — what Khayt's
pull-merge-repush reaches by a longer road.

### The promise a storefront quotes

`PUT /v1/shops/{id}/lead-time`, from `LeadTime.swift`, every six hours.

This was the last thing only the Electron **main process** did, and it is the
sharpest example of why "the Mac app is nearly there" was the wrong way to read
this project. A storefront refuses to quote at all once the snapshot passes
`staleAfterHours` — 24 by default — so a Mac where somebody shut Electron down
took the shop's published delivery dates offline a day later, silently, with
nothing on any screen in either app to say so. The feature broke by succeeding
at the goal.

`lib/lead-time.js` and `lib/lead-time-publish.js` are bundled rather than
ported, so both apps make the same promise from the same book. Three things are
worth knowing:

* **The body is NOT encrypted.** Everything else this app sends the cloud is
  sealed with the shop's DEK; a storefront holds no key. The discretion is in
  the module instead — the snapshot carries `availableFrom` and a handling
  allowance and deliberately never the queue, because hours of booked work
  published hourly is a competitor's view of how busy a shop is.
* **It waits for the printers.** `lead-time-publish` asks the status cache what
  each machine is doing, and a machine it finds nothing about is a machine with
  nothing on it. Publishing before the first poll lands would price the shop's
  capacity as though every printer were free — and would overwrite a snapshot
  Electron had published from a cache that DID know. Two apps, one shop, and the
  one with less information wins by being later.
* **`PrinterWatch.statusCache` carries `timeRemaining` because of this.** It did
  not before, and the omission was not neutral: every printing machine fell into
  "busy, duration unknown" and dropped out of the shop's capacity, so a shop with
  one busy printer published a promise computed against no printers at all.
  Measured on this bench the day it was wired up — the same book gave
  `availableFrom: 2026-09-05` without the field and `2026-09-06` with it.

The task's lifetime is the BOOK's, not the load's. `load` runs again every time
the store changes on disk, and a version that restarted the timer there
published nothing at all, for ever: the task opens with a ninety-second wait and
a book touched more often than that resets the clock before it expires. It was
watched doing exactly that, with a trace attached, before `startPublishingLeadTime`
learned to leave a running task alone.

### The dashboard

The screen the app opens on. `lib/attention.js` and `lib/dashboard-facts.js` are
bundled and run, so what counts as late here is what counts as late in the shop's
other app — both pure, zero requires, already assigning onto `globalThis`.

**`lib/kpi.js` is deliberately NOT bundled.** It takes rows a caller has already
scoped to a date range, converted to base currency and marked completed and
on-time; `renderer/analytics.js` does that in a private `rowsFor(range)`. Handed
`{orders, settings}` it compiles, runs, and returns **every figure as zero** —
which is how this screen briefly showed "0 SAR revenue" beside a toolbar reading
52,691.57. Revenue and margin wait until that normalising is lifted into `lib/`
where both apps can share it. A bridge method that quietly answers zero is worse
than no bridge method.

That is fixed. `lib/kpi-rows.js` and `lib/order-money.js` were lifted out of the
renderer, and the money section now shows revenue, gross profit, margin, average
job and on-time — all from the shared modules, for a period you choose. The
margin here is the margin the Electron app shows, because it is the same three
functions: `order-money` prices an order, `kpi-rows` says which orders count,
`kpi` adds them up.

The money function is written in JavaScript inside `KhaytEngine.kpis` — a
function cannot cross the JSON bridge — and it is the renderer's own three calls.

**Two tiles are deliberately absent.** There is no second "Late": the floor
already has one from the attention engine, and the money section's counted
something subtly different (unpaid *and* overdue). And there is no "Owed": `kpi`
scopes outstanding to the period, while the toolbar shows what the whole book is
owed, unscoped and always visible — two figures under one word, inches apart,
differing by an order of magnitude.

### The board

Every open job in the column its stage puts it in. The table answers "what is
the state of this job"; the board answers "where is the work piling up", which is
the question a shop asks standing in the middle of the room and the one a list of
forty rows sorted by date cannot answer at a glance.

Cards sort urgent first, then by due date, then by what has been waiting longest
— the order someone would work through them in. Delivered and cancelled are off
the board on purpose: a column of two hundred delivered jobs buries the four that
need doing. An empty column keeps its width and says "nothing here", because a
board whose columns collapse as work moves is a board you cannot learn.

**READ-ONLY, AND THAT IS THE POINT.** Dragging a card between columns would be a
status change, and a status change in Khayt is not a field write: it stamps
`completedAt`, moves the customer's progress tracker, and can settle an
instalment plan — 3,200 lines of `renderer/order-flows.js` worth of rules. A
Swift reimplementation of the most consequential write in the app is exactly what
this project refuses to do. Dragging arrives when those rules are shared, the way
the money rules now are.

### The shop floor

Machines as cards — a shop has a handful of printers, not four hundred, and what
you want from one does not line up into columns worth scanning. Filament as a
table, with the per-kilo cost worked out, which is the number that compares two
suppliers.

Nozzle wear comes from `lib/nozzle-wear.js` — bundled with
`lib/nozzle-wear-data.js`, **which must load first**: `nozzle-wear` reads it
through `require`, and under JavaScriptCore there is none, so it falls back to
`global.KhaytNozzleWearData`. Without that file the module still LOADS and then
throws on the first call. Verified identical to Node's answer.

**The machine's address is shown; its key never is.** The store keeps that
encrypted and a screen saying where a printer lives has no business opening it.

### Three shared modules, three signatures I got wrong by assuming

All in one afternoon, and the pattern is worth the space:

| Module | What I passed | What it wanted | What it did |
|---|---|---|---|
| `kpi.computeKpis` | `{orders, settings}` | rows already scoped and converted | returned every figure as **zero** |
| `nozzleWear` | one options object | `(printLog, machine, settings)`, positional, **per machine** | reported every nozzle at the default 5,000g threshold instead of its own |
| `filament-dryness` | inventory rows | Bed Ready dry-log records keyed on `driedAt` | a column of dashes — the module does not apply to this collection at all |

None of the three failed. Each returned a plausible object that rendered
perfectly and was wrong. **Read the function, not the name** — and when a module
turns out not to fit the data, unbundle it rather than keeping a column that
would go wrong the moment somebody filled the field in.

### How the library is ordered

**The default is not "by name".** `renderer/printfiles.js` sorts favourites
first, then most recently updated, and a shop that switches between the two apps
and finds its models in a different order has been given two libraries. This app
opens the same way round, and View ▸ Sort Library By offers name, size, last run
and times printed. The choice is remembered.

Two small decisions inside those orders, both tested: **by size is biggest
first**, because the reason to sort by size is to find what is filling the disk;
and **a model that has never run sorts last**, because an absent date must read
as "long ago" rather than "now" — otherwise the least useful models would be the
first thing a shop sees under "Last run".

### The keyboard in the library

Arrow keys move the selection, ⇧ extends it, ⌘A selects everything on the shelf,
⏎ opens, ⎋ clears. A `List` gets all of that free; a `LazyVGrid` gets none of it,
and a grid you cannot walk with the arrow keys is the most un-Mac thing an
otherwise native window can do.

Three things it turns on:

* **The columns are fixed, not `.adaptive`.** Moving down is moving forward by
  one row, so the count has to be known — and `.adaptive` decides it privately.
  `LibraryGrid.columns(across:)` is that count, and is tested for being
  monotonic and never zero.
* **The arrows follow reading order, not the screen.** In a mirrored window the
  next model is to the LEFT. `LibraryGrid.step(for:columns:layout:)` is that
  rule, alone and tested, because a right arrow that walks backwards is the kind
  of thing nobody notices until an Arabic shop does. It was also written first as
  `case forward:` inside the key handler — one character from `case let forward:`,
  which would have matched everything.
* **Two positions, not one.** `anchor` is where a selection run started and
  `cursor` is where the keyboard is standing. Computing the next place from the
  anchor — which is what it did first — means a second ⇧-arrow lands where the
  first did and the selection never grows past two. Caught by its own test.

A key at either end is left **unhandled** rather than clamped, so the system beep
still means "there is nothing that way". And there is no focus ring around the
pane: Finder, Photos and Music all show keyboard focus through the selection, and
a blue rectangle enclosing the grid reads as an error state.

### Undo

Every edit is reversible — ⌘Z, with the Edit menu naming what it will undo
("Undo Add to Favourites", "Undo File in Saudi Kings"). Those items have always
been in the menu; until now they did nothing, which is worse than their being
absent: an item that is enabled and inert teaches people not to trust the menu.

What is captured is the WHOLE record as it was, not the fields about to change,
so an undo also puts back a field some later version of the edit starts touching
and forgets to snapshot.

**`rev` is the exception and does not go backwards.** An undo is an edit like
any other and stamps a new revision. A record whose revision went back would
look to the next sync exactly like the change never happened, and the other
machine's copy would win — the undo undone, by a laptop, quietly.
`StoreWriter.restoring(_:over:)` is that rule, alone and tested.

Verified end to end on the real store, with a backup: `false → true → false`,
one record touched, only `rev` and `updatedAt` left different, rev 3 → 5 (the
edit and the undo, both forward), secrets byte-identical, store restored
afterwards.

## The menu bar

Everything the app can do is in the menu bar with a key for it — ⌘1/2/3 for the
three shelves, ⌘R reload, ⌘D favourite, ⇧⌘R reveal, ⌘O open. A menu you have to
know is there is a feature for the person who wrote it.

**The items are Views, and the shop is handed to them.** Two problems, and the
fix for the second is what fixes the first:

* A `Commands` body does not re-run when an `@Observable` it read changes, so
  items built straight into `Commands` freeze in the state they had at launch.
  The developer forums' answer — put the items in a `View` — is right, because a
  View body does re-run.
* `focusedSceneValue` / `@FocusedValue` is the documented way to tell those views
  which shop to act on, and it **delivers nil here**. Tried under `Window` and
  `WindowGroup`, declared with `@Entry` and with an explicit `FocusedValueKey`,
  read from a `Commands` type and from a `View`. So the shop is handed down; the
  indirection starts paying for itself at the second window.

**⌘A is the system's.** Adding a rival "Select All Models" to the Edit menu
simply loses — SwiftUI drops the shortcut on the second claimant, and the item
ends up with no key at all. The grid handles the standard command when it has
focus, which is how a Finder window does it.

### Photographing it in the dark

The runner takes three shots in dark mode before the light pass, and it took
three attempts to make them true.

`cacheDisplay` draws with whatever `NSAppearance.current` happens to be, and
outside a real draw cycle that is aqua — so every dynamic system colour resolved
LIGHT however the app was set. Drawing inside
`view.effectiveAppearance.performAsCurrentDrawingAppearance { … }` fixes that.
And the appearance has to be set on the WINDOWS as well as on `NSApp`, before
the window settles: flipping it afterwards leaves the sidebar's `NSTableView`
holding cells that were already built with light label colours.

**The sidebar still does not photograph in dark mode**, and that is a limit of
the camera rather than a bug in the app: it is a vibrant view, and a
`cacheDisplay` of one has no backdrop to blend against. The content area — which
is where every custom colour in this app lives — does render correctly, and the
library grid in dark is the shot worth looking at. For the sidebar, read the
source: `grep` for `.white`, `.black` and `Color(red:` finds two hits, both the
palette capsule over a thumbnail, which is over a photograph rather than over
the window and is right in both appearances.

### Reading the menu bar in a snapshot run

`KHAYT_SNAPSHOT_DIR` runs print the menu bar as AppKit built it — titles and
shortcuts.

**They deliberately do not print enabled state, and that cost two afternoons.**
AppKit validates items against the responder chain when a menu is about to open,
and a snapshot run never establishes one, so every item reads as disabled —
including Cut, Copy and Paste. That looks exactly like a broken focused value and
is nothing of the kind. Both times, the thing that was actually true came from
STRUCTURE: the Book menu's picker is built inside an `if let shop`, so its
presence says the shop reached the menu and its absence says it did not.

**No `Settings` scene yet**, so ⌘, does nothing. An empty preferences window
would be worse — there is no setting this app owns that is not either the shop's
(which lives in the book) or the Book menu's.

## Who owns the store

The constraint below is now written down on disk rather than assumed.

`lib/store-lock.js` decides who owns `khayt-store.json`; Electron takes ownership
for its whole session, refreshes a heartbeat, and drops it on quit.
`StoreLock.swift` reads that record and the Mac app says who has the book — it
never takes the lock, because it does not write, and a reader claiming ownership
would shut a shop out of its own app for nothing. When writing arrives, that
check is what gates it.

**Ownership, not a lock around each write.** Per-write locking looks smaller and
does not work: `updateStoreOnDisk` reads the in-memory `getStore()` in preference
to the disk, so a second process could take a perfectly correct lock, write,
release, and have its change overwritten by the incumbent's next save from
memory. What has to be exclusive is the session.

**Liveness beats time.** A lock is broken because its process is gone, not
because a clock says so — an app paused at a breakpoint or busy through a long
import is still the owner. The heartbeat is consulted in exactly one case: a
record written by another machine, where there is no pid to ask about.

Two traps, both found by running the two implementations against each other
rather than by reading either:

* **Node and Swift spell this machine differently.** `os.hostname()` gives
  `Turkis-MacBook-Air.local`; `ProcessInfo.hostName` gives
  `turkis-macbook-air.local`. Compared raw, the Mac app reads Electron's lock as
  foreign, stops checking liveness, and judges a live holder on the clock. Both
  sides fold case before comparing.
* **A heartbeat from the future is not stale.** Two machines never agree on the
  time, and treating a negative age as old breaks a live holder's lock instantly.

`test/store-lock.test.js` covers the rules; `StoreLockParityTests` runs sixteen
cases through Node and Swift and compares; and the E2E smoke asserts the running
app actually wrote a record naming its own live process — delete
`acquireStoreOwnership()` from main.js and that fails.

### Writing

`StoreWriter` is the only code in this app that can lose a shop's data, so it is
built around three rules:

* **It never decrypts.** The secrets on disk are already `__enc__` strings, so an
  edit to another field carries them through untouched and `SafeStorage` is never
  involved — decrypting to re-encrypt would put a working credential one bad round
  trip away from unreadable, for nothing. The price is that the whole store goes
  through a JSON decode and encode, so `StoreRoundTripTests` proves a real store
  survives that value for value. If it did not, every record's fingerprint would
  move and `stampChanges` would push the entire book to the cloud as changes
  nobody made.
* **It reads from disk, inside the write** — never from anything already held.
  `updateStoreOnDisk` learned that one the hard way.
* **It writes only while it owns the book**, checked before the read and again
  immediately before the swap, so the window in which Electron could take over is
  one serialisation wide rather than a whole edit.

It stamps `rev` and `updatedAt` the way `renderer/sync.js` does. That is not
politeness: the renderer's sync baseline is an in-memory index seeded from the
store on load, so an unstamped edit would look to the next Electron launch
exactly like the state the book had always been in, and would never reach the
cloud.

Verified on a copy of a real store, and once on the real one with a backup: of 34
collections only `printFiles` changed, of its records only the one named, and of
its fields only `favorite`, `rev` and `updatedAt`. Secrets byte-identical.

### Reading a group

`groupOf` is the one part of `organise.js` written twice, because asking a
JSContext for the group of every row to draw a sidebar of four hundred models is
a call per row for an answer that is two field reads. `OrganiseParityTests` holds
the copy to the original, and caught two things I had wrong:

* **The PRESENCE of `folder` decides, not whether it holds anything.** A shop
  clearing the box on an older build leaves `folder: ''`, and that empty string is
  the instruction. Falling back to `group` there brings back the name they just
  deleted.
* **`normalise` does not strip control characters.** A NUL in this field has
  caused trouble elsewhere in Khayt and the instinct is to strip it — but
  JavaScript's `\s` does not match NUL, so neither may this. Whatever the two
  apps do here they must do identically.

A third was in the test rather than the code: it restated the rule instead of
calling it, and so agreed with the mistake. It calls `LibraryFile.groupName` now.

## Words

The app speaks Khayt's own vocabulary. `renderer/locales/en.js` and `ar.js` are
bundled and run in JavaScriptCore alongside the logic modules, so a stage this
app calls "قيد الطباعة" is called that because the Electron app calls it that. An
app that invents its own word for "Owed" has given one shop two vocabularies, and
the person reading the second has to work out that it means the first.

`Words.own` holds the handful of things Khayt has never needed a word for — "On
this Mac", "Opened read-only". They are kept there rather than added to the
shared catalogue because that one is nine languages wide and guarded for
completeness: adding a key there means adding it in nine, and an English value
sitting in `ar.js` is exactly what `test/locale-quality.test.js` exists to catch.
`WordsTests` proves every borrowed key exists in both bundled languages, every
own key carries both, and that neither catalogue shadows the other.

Language comes from `settings.lang`. Not the system: a Riyadh shop on an English
Mac still keeps its book in Arabic, and the book is what this window shows. (The
Electron app keeps the live choice in `localStorage`, which nothing outside it
can read; `settings.lang` is the copy that travels with the store.)
`KHAYT_LANG=ar` forces one run, which is the only way to photograph a language
the shop does not use.

### Right to left

An Arabic shop gets a mirrored window: sidebar on the right, columns reversed,
inspector on the left, traffic lights on the right.

**Not via `.environment(\\.layoutDirection, .rightToLeft)`.** That line sends
SwiftUI's `NavigationSplitView` into an unbounded layout loop on macOS 26 —
`SplitViewChildController.hostingView(_:didUpdateMinSize:maxSize:)` re-invalidates
every pass, the window grows past 3000pt, and AppKit aborts with *"more Update
Constraints in Window passes than there are views in the window"*. It is not the
sidebar's or the inspector's width constraint; removing either changes nothing.

The way that works is the way AppKit has always done it. `Direction.settle()`
sets `NSForceRightToLeftWritingDirection` and `AppleTextDirection` — the two
defaults Apple documents for [testing right-to-left
layout](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPInternational/TestingYourInternationalApp/TestingYourInternationalApp.html)
— and the whole application flips. SwiftUI is never asked to mirror anything, so
there is nothing for it to loop over.

**AppKit reads those once, on the way up**, so this has to happen before
`NSApplicationMain`. That is why there is a `main.swift` and why `KhaytApp` is
not `@main`. When the answer differs from last launch the app `execv`s itself
once — guarded by an environment variable so it can never do it twice — which is
also why changing a shop's language takes effect at the next launch rather than
immediately.

Both keys are always written, never only the true one: a shop moving from Arabic
to English would otherwise keep a mirrored window for ever, because the value it
set last time is still in its own defaults. Round-trip verified — ar → en → ar,
mirrored, unmirrored, mirrored, no crash in any direction.

Resolving the language reads the store before AppKit exists: 3ms on a real 958KB
book, bounded by the 50MB cap.

## The one hard constraint

**Only one app may own the store at a time.** Khayt's write serialisation is
per-process: two processes on one `khayt-store.json` race exactly the way two
shop-floor tablets did before #898. Either the Mac app replaces Electron on that
machine, or the second one opens read-only behind a lock.
