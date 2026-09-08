# Changelog

All notable changes to Khayt are documented here. Version format: [VERSIONING.md](./VERSIONING.md).

## [Unreleased]

### Added


- **The space bar answers the question too.** Pressing space on a `.3mf` in
  Finder shows the plate render large, with the printer, layer height, nozzle,
  material, infill and supports underneath — the same facts the library
  inspector shows, laid out by the same code, so Finder and Khayt cannot start
  telling a shop different things about the same model. In Arabic it is in
  Arabic and mirrored, and the unit lives in the label rather than being an
  English word appended to a number.

  It reads the shared rules, which means it carries them: an extension's
  `Bundle.module` resolves against the `.appex`, not the app around it, so
  without its own copy it launched, found its extension point, and died on
  `could not load resource bundle` the instant a preview was asked for — with
  Quick Look quietly falling back to scaling the thumbnail, which looks almost
  right and has no facts under it. Two tests now hold that: one that the bundle
  is there, one that nothing loose sits in an `.appex`'s root, where it would
  break the code signature.

- **The library says how a model is set up to print.** Printer, layer height,
  nozzle, material, infill and supports, read out of the slicer's own settings
  inside the file. It is the question a shop asks second: a folder holds the same
  shape sliced for a U1 and for an X1 Carbon, at three layer heights, one with
  support and one without, and the pictures are identical.

  Read from the FILE rather than captured at import, so a model re-sliced for a
  different machine stops claiming to be what it used to be, and so every model
  imported before today has it too. Nothing is estimated: there is no print time
  and no filament weight here, because those exist only in a sliced 3MF and not
  one of the 43 files in this shop's library carries them — a row that is empty
  on every real file teaches people the panel is broken.

  TWO THINGS IT REFUSES TO GET WRONG. An object's own settings beat the
  project's, and 14 of those 43 files set one: the king plates say 100% infill on
  the object where the project says 15%, and reporting 15% would be a straight
  lie about what the file prints. And a support STYLE is shown only when support
  is actually on — every one of these files carries a `support_type` whether or
  not it is used, so "tree (auto)" beside a model that prints without support was
  the easiest wrong answer available.

  The rule is `lib/print-facts.js`, shared, so Khayt and the Mac cannot hold two
  opinions about what a model prints in. PrusaSlicer spells the same ideas
  differently — `fill_density`, not `sparse_infill_density`; `support_material`,
  not `enable_support` — and those names were read off this Mac's own PrusaSlicer
  profiles rather than remembered.

- **A 3MF looks like the thing it prints.** Finder, Spotlight and Quick Look show
  the plate render that is already inside the file, so a folder of models is ten
  different pictures instead of ten identical blank pages. Nothing is rendered
  and no mesh is read: a 3MF is a zip, the slicer wrote a PNG into it, and that
  PNG is 160 KB sitting beside 436 MB of triangles. A file a CAD program wrote
  with no render in it shows the ordinary icon, which is what it showed before.

  TWO THINGS MADE THIS TAKE A DAY, AND NEITHER IS IN ANY DOCUMENTATION. macOS 14
  and later launch a thumbnail extension through ExtensionKit, which looks for a
  Swift entry point in the binary FIRST and only falls back to the declared
  provider class when it finds none — so `main.swift`, whose entire body was a
  message saying it should never run, was what ran. The extension launched and
  was gone in 38 ms, every request came back `QLThumbnailErrorDomain 102`, and
  the provider was never built. Apple's own thumbnail extensions have no Swift
  entry point either; ours has none now, and a test fails the build if one comes
  back. The second: the extension must be sandboxed. Its extension point
  declares `EXSandboxProfileName = quicklook-thumbnail`, and one signed without
  the sandbox entitlement registers, matches, and then fails every request in
  exactly the same way, which is a good way to spend an afternoon on the wrong
  theory.

- **macOS knows what a .3mf is.** It did not: `mdls` on one of this shop's models
  reported a `dyn.*` placeholder, which is what a type nobody has declared looks
  like — no kind, no icon, ten identical blank pages in a Finder window, each one
  a different model. Khayt declares the type now, so a 3MF has a name and an icon
  in Finder, in Open dialogs and in Spotlight. It does not claim to OPEN them:
  the slicers keep that, and double-clicking one still opens the slicer it always
  did.

- **The floor is in the menu bar.** A print runs for eleven hours; nobody keeps a
  shop-management window open for eleven hours to answer *is it still going, and
  when is the printer free?* The nozzle in the menu bar carries the number of
  machines running, and clicking it shows each one, what is on it, how far in and
  how long is left — with the way in to the app and, when there is unassigned
  work, straight to the scheduler.

  It can be turned off in Preferences. That switch is Mac-local and deliberately
  not a shop setting: whether this Mac shows an icon is nothing to do with the
  book and has no business following it to another machine.

  WRITTEN TWICE, AND THE SECOND ONE IS APPKIT. SwiftUI's `MenuBarExtra` is three
  lines and made the app unusable: the snapshot runner went from a full pass in
  ninety seconds to seven pictures in as long, and a sample of the stuck process
  put 706 of 846 samples inside `makeMainMenu`. A `MenuBarExtra` is a scene, and
  every change to the scene graph rebuilds the whole main menu — so a menu bar
  item watching a live shop rebuilt the File menu every time a printer reported a
  temperature. An `NSStatusItem` is not in that graph: its title comes from a
  five-second timer and the panel is built when somebody opens it and dropped
  when they close it, so nothing is evaluated while nobody is looking. The full
  pass is 64 seconds with it installed.

- **Khayt answers the Mac without being opened.** "What is printing" and "What is
  waiting to print" are now actions the system owns: they appear in Spotlight and
  Shortcuts, Siri can be asked them, and an automation can run one at seven in the
  morning with nobody present. They read the book on disk and nothing else — no
  window, no engine, no printer poll — so the answer arrives faster than the app
  could open.

  That constrains them on purpose to facts the book STATES rather than facts a
  rule derives. "Printing" is a status somebody wrote down; "late" is a judgement
  `lib/attention.js` makes about due dates and voided orders, and it is not
  re-implemented in Swift to save a launch.

  The build had to grow a step for this. Xcode discovers `AppIntent` types by
  emitting per-file const values and running `appintentsmetadataprocessor` over
  them; SwiftPM does neither, so the intents compiled, linked, and would have
  been invisible to every part of macOS — a verb nothing could call. `make-app.sh`
  now asks the compiler for the const values, builds `Metadata.appintents` and
  signs it into the bundle, and says how many actions it found. It says so loudly
  when it finds none.

  The verbs themselves are English. Khayt translates at runtime from its own
  catalogue and App Intents titles are read by the system at registration, which
  wants a string catalog this hand-assembled bundle has not got. The ANSWERS are
  in the shop's language.

- **The Mac can say which printer should take which job.** Khayt has had a
  print-farm scheduler since 3.0 — it places waiting work by due date, material,
  nozzle and how loaded each machine already is — and the Electron kanban has
  used it all along. The Mac could not schedule at all, because the module was
  never in its engine's list. Printers → Suggest assignments now proposes a
  printer for every waiting job, with the reason beside it, and the jobs it
  cannot place with the reason for that: "no compatible printer" against a resin
  job is the app telling a shop what its fleet cannot do.

  It proposes and stops there. Nothing moves until somebody presses Apply, which
  is the contract the scheduler was written to and the one the kanban has kept.

  Not a line of the scheduling is written in Swift: the Mac runs
  `lib/scheduling.js`, and a differential test compares the whole proposal —
  printer, queue position, projected finish and reason — against Node on the
  same JSON.

  One thing the Mac does that the Electron panel does not: it hands the
  scheduler the work still to happen rather than only the unassigned jobs, so
  each machine's queue is seeded with what is already on it. Given only the
  unassigned rows the module sees every printer as empty and reports each job
  finishing within minutes of now.

- **The Mac can price a job without taking it.** A calculator, in the sidebar and
  at ⇧⌘K: a weight, a print time, how many, which spool and which printer, and it
  says what the work costs the shop and what to charge for it — with the four
  buckets the cost is made of. Until now the only way to get that answer here was
  to create a job, read the number and delete it, which is not something anybody
  does with a customer waiting.

  Not one line of the arithmetic is written for this screen. It goes through the
  same two calls the New Job sheet uses, so a quote worked out here and the same
  job taken through the sheet agree to the halalah. Choosing a printer matters
  for the same reason: the wear, power and electricity rates come from that
  machine and this shop's settings, so the answer is what you would charge rather
  than a general one.

  It opens on a real spool rather than on none, because without one there is no
  cost per gram and the material bucket — the largest part of most prints — comes
  out at zero. On a 180-gram part that is thirteen and a half riyals missing from
  a price that otherwise looks finished. If a spool is deliberately not chosen,
  the screen says in words that the plastic is not counted.

- **The Mac writes the file a shop gives its accountant.** File → Export for the
  Accountant, in the layout QuickBooks, Xero or Zoho Books wants — or plain CSV
  — and two files land in the folder you pick: one of invoices, one of expenses.
  Until now the Mac could export the whole book as JSON, which is the right
  thing to hand a support thread and the wrong thing to hand a bookkeeper:
  nobody opens a thirty-three-collection JSON in the software that files a VAT
  return.

  What a row SAYS — that a quote is not an invoice, that an order with no price
  is not one either, what the shop's VAT rate and pricing mode are, which
  customer a job belongs to — was decided in the Electron window and nowhere
  else. It is a shared rule now, so the same quarter exported from either app is
  the same rows to the halalah. That matters more here than anywhere else in
  Khayt: two apps disagreeing about a VAT figure is a disagreement an auditor
  finds.

- **A model can say where it came from and what its licence allows.** A shop's
  library holds work it made and models it downloaded, and they look identical
  in a grid — while most of what is on the model sites is Creative Commons and a
  good share of that is NonCommercial, which is the licence that makes selling a
  print of it a breach rather than a favour. Both are fields on a model now, set
  in Khayt's model editor and shown on the Mac, and a model that may not be sold
  says so in words as well as colour. A model nobody has recorded a licence for
  says **nothing** — not knowing is not the same as not being allowed.

- **The Mac app converts a 3MF.** In the Model menu, or right-click a model in
  the library, and pick **Convert for** — twenty-two printers, or a clean standard 3MF — and choose
  where to save it. Retarget a model to another printer, or normalise it,
  without Electron running. The container
  is opened and rebuilt by the Mac itself and the decisions come from the same
  shared rule the other app uses, so a file converted on either opens the same.
  The geometry never enters the app at all — it is copied across still
  compressed — which is how a conversion cannot corrupt it. The two colour
  strategies that rewrite the model itself, Full Spectrum and band-swap, say so
  plainly and stay in Khayt for now.

- **The 3MF converter's decisions can now be asked for on their own.** Groundwork
  for running it outside Electron: the reading and writing of the container are
  Node's zlib and nothing else in that module is, so the part that decides what
  a converted file should contain now has a door of its own. Nothing about a
  conversion has changed — the same members come out, byte for byte.

- **OBJ models are measured and drawn like the rest.** The third format a
  library holds, and the one the mesh reader knew nothing about — so an OBJ was
  never measured, never had a size to check against a printer's bed, and stayed
  a grey square while every STL beside it gained a picture.

- **The Mac draws a preview for a model that has none.** A 3MF carries a picture
  its slicer made; an STL carries nothing but triangles, so a shop that imports
  a folder of them gets a library of identical grey cubes. The geometry is right
  there — the app already reads every triangle to measure the model — so it is
  drawn: a three-quarter view, shaded, from the mesh itself. New models get one
  as they are imported, and `Khayt --import --previews` catches up a library
  that already exists, drawing a picture for a model that has none and recording
  a measurement for one that was never measured. A model that has both is left
  alone, so running it twice costs nothing.

- **The Mac can write a 3MF, not only read one.** Groundwork for the converter,
  which is the last thing the Mac app cannot do that the Electron one can: it
  could already open a 3MF — it measures meshes and pulls thumbnails out of them
  — and had no way to put one back together, because the writer next door is
  built on Node's zlib. Archives it produces are read by the system `unzip` and
  by Khayt's own Node reader, and it opens the ones that reader's writer makes.

- **The Mac says whether a model will go on a printer you own.** A model's size
  and a machine's bed were both already in the book, and the rule that compares
  them lived inside the converter — so the first question a maker asks could
  only be answered *during a conversion*. The library inspector now says it
  outright: which machine it fits, whether turning it sideways would do it, or
  that it is too big for everything on the floor. Silent when a machine has no
  bed recorded, because not knowing is not a refusal.

- **Gift cards on the Mac.** The cards a shop has issued, what is left on each,
  who it went to and whether it can still be spent — and a button to issue
  another. It was the last screen the Mac app was missing that the Electron one
  had, apart from the converter.

- **`Khayt --import <folder>` on the Mac.** The same import as the File menu,
  from a terminal, so a library of thousands can be started from a script and
  rehearsed first: `--dry-run` prints every file it would take and writes
  nothing. `--keep-originals` copies rather than moves. It runs without opening
  a window and takes the same store lock the app does, refusing by name if Khayt
  has the book open.

- **The Mac app imports many models at once, and folders.** Adding a model was
  one trip through the file picker per file, which is not an import when a shop
  has three thousand of them in nested folders. Pick any mix of files and
  folders now and it walks them, skipping anything Khayt does not read and its
  own library folder, with a progress bar, a running count, the name of the file
  it is on, and a Stop button.

- **Colour studio on the Mac.** Pick a colour and the app ranks the filament
  you already own by how close it *looks* — perceptual distance, not the
  nearest hex — and blends any two spools into a gradient of as many steps as
  you want. Same maths as Khayt's own colour screen.

- **Portfolio on the Mac.** Every photograph on every job, in one grid, so
  showing somebody what you can make does not mean opening nineteen orders.
  Double-click opens the full-size photo. The row only appears once there is a
  photograph to put in it.

### Changed

- **The Mac app draws its own subject.** Counted before any of this: forty-three
  distinct system symbols, twenty-nine stock empty states, and zero drawn shapes
  — not one. Every mark on every screen was Apple's, arranged by us, which is
  what "it looks generic" turned out to mean and why three rounds of better
  arrangement did not touch it. Khayt is about a craft with a visual language of
  its own — a nozzle, a bead of plastic, layers cooling — and none of it appeared
  anywhere except in the words. Twenty screens that have nothing on them yet now
  show a nozzle laying a first layer, drawn by the app, instead of the same grey
  glyph every Mac app shows. A printer's progress is drawn as the stack itself,
  filling from the bed upward, because that is what the number means.

  The Arabic letter in Khayt's mark is deliberately **not** redrawn. A letterform
  approximated by somebody who cannot read it is wrong in a way its readers see
  at once and its author never does; where the mark is wanted the app uses its
  own icon, which is already correct. And a book that will not open keeps the
  system's warning glyph — that is a failure, not an empty screen, and the drawn
  nozzle would say the wrong thing cheerfully.

- **An invoice draws the Saudi Riyal mark instead of trusting the reader's
  fonts.** Every price in the app already carried the official mark; the
  document a customer is actually handed still said "SAR", because the invoice
  formats against a currency table that predates it. The app can afford the
  character — it asks the system whether the font it is drawing in has the glyph
  and says SAR when it does not. **A PDF cannot ask.** It is opened on a machine
  the app will never see, in a reader whose fonts it cannot inspect, and the
  codepoint only arrived with the mark in 2025 — so on anything older a price
  renders as an empty box on a customer's invoice, which is worse than the
  letters. So the mark is geometry now, the official symbol drawn as a path,
  which needs no font at all. Every other currency keeps its own symbol, and
  nothing about the ZATCA QR changes: it carries the total and the tax as
  numbers and never saw the symbol.

- **The Mac app looks like Khayt now, rather than like a SwiftUI app.** The
  palette was already chosen and contrast-checked, and almost none of it reached
  the screen: every panel in the app was the same grey rounded rectangle, so
  nine sections down the dashboard and eight figures across it were all drawn
  identically and the screen had no way of saying which of them mattered. Three
  things changed. Screens sit on a warm off-white ground with the cards raised
  on it — in light appearance a macOS window is pure **white**, so a card could
  not be lifted at all and every panel was necessarily a grey box laid on top;
  the ground had to move instead. Cards carry a short coloured **rail** down the
  leading edge saying what they are about — amber on a machine that is printing
  right now, red on a late job, the app's cyan on the shop's own figures — and
  a card with nothing to say has no rail, which is what keeps the ones that do
  worth looking at. And the takings for the chosen period are drawn as one large
  figure with profit and margin beneath them, instead of as the first of eight
  identical tiles that gave a month's revenue the same weight as the number of
  files in the library.

- **Every screen on the Mac sits on the same background.** The jobs, customers,
  expenses and waste screens painted the system's white while the dashboard, the
  board and the library sat on the app's own ground, so moving between them
  jumped. In Reports and Expenses, where a table sits beside a summary pane, it
  drew a hard seam down the middle of the window — two halves of one screen
  looking like two documents. The tables let the ground through now; their
  alternating row stripes are still the system's.

- **Every screen on the Mac is laid out on the same margin.** It was 14 on
  Reports, 16 on the library, the machines, the board and the portfolio, and 20
  on the dashboard — four values for one decision, none of them chosen. They are
  all 20 now, which is Apple's published margin for macOS content, and the
  numbers have names and a source rather than being typed at each call site.
  Nobody notices a 20-point margin; everybody notices that two screens in the
  same app do not agree.

- **The Mac's sidebar is wide enough for its own words.** It was 190 points at
  its narrowest, under every published minimum for a Mac source list, and the
  app had been paying for it in a test that caps every sidebar label at 22
  characters because longer ones truncate — Arabic set the cap. The column
  starts at 225 now and the twenty-five points come out of a detail pane that is
  hundreds wide.

- **The Mac's reports say their answer first.** Net income was the fourth line
  of a four-line list, set at the same size as the VAT it is not — and it is the
  figure the screen exists to give. It is now the large one at the top of the
  pane, red when the shop lost money and uncoloured when it did not, with the
  revenue, expenses and VAT it is made of beneath. The aged-receivables buckets
  and the two Best lists are cards rather than shapes floating on the window.

- **A job's stage has a colour on the Mac, and only where it means something.**
  The jobs table drew every row's stage in the same grey, and the board knew
  about exactly one of the nine states it draws. Four of them now carry the
  colour the palette already defines in words — printing is the amber that means
  something is being made right now, on hold the amber that means it wants a
  person, completed and delivered the green that means finished, cancelled the
  red. The other five are the ordinary course of a job and stay the colour of
  ordinary text: nine stages in nine colours is a rainbow, and a rainbow is what
  a colour scheme looks like once it has stopped meaning anything.

- **The Mac's profit-and-loss report stops drawing rows it does not have.** One
  row per quarter, two of them on a young book — and the striping was drawn down
  the whole window regardless, so a shop read two figures above a dozen empty
  grey bands and reasonably wondered what had failed to load.

- **Prices on the Mac carry the Saudi Riyal mark, not the letters SAR.** Every
  figure, every unit label beside a money field, and the OWED badge in the
  toolbar. On a Mac whose system font does not have the mark — it arrived with
  the font after the symbol was adopted in 2025 — the letters stay, because a
  price that is an empty box is worse than one that is merely older. Other
  currencies keep their codes.

- **The Mac's jobs table stops showing columns this book never fills.** A shop
  whose work is auto-logged from its printers names no customer and promises no
  date on any job, so two of the six columns said so on every row — four of the
  six carried nothing at all. They are hidden the first time such a book is
  opened, and they are in the header's menu like every other column, so a shop
  that wants one back can have it and the choice sticks.

- **The Mac dashboard fits about twice as much on a screen.** Both of its lists
  stacked the order number underneath the job name, which doubled the height of
  every row — six late jobs filled the window and the seventh was below the
  fold, which is the one thing a list of what is wrong must not do. The number
  sits beside the name now, and what used to be two and a half sections is the
  attention list, the floor, the invoices to chase and the month's money.

- **Jobs and the board show what was printed.** A job whose parts name a library
  model now carries that model's picture — in the table and on the board card —
  and every job says which colours it is being printed in, in the shop's own
  words. Both screens were columns of text about physical, coloured things, and
  the pictures were in the library all along.

- **The Mac's filament shelf is a shelf now, not a table.** Six spools came back
  as six rows of grey text over a twelve-pixel colour chip, followed by a dozen
  empty striped rows that made a stocked shelf look like a broken screen. A
  filament shelf is read by colour first — it is how a spool is picked off a
  rack — so the colour is the row: a spool seen face on, big enough to tell from
  its neighbour, with what it is, how much is left, and an amber ring and a
  **low** badge on anything about to run out. The grid stops where the spools
  stop.

- **Adding a model MOVES it into the library instead of copying it.** A shop
  importing what it has downloaded does not want a second copy of thirty
  gigabytes, and the vault is meant to become the one place a model lives. The
  original is removed last, only once the bytes are at the destination, have
  been read back and compared, and the book holds a record pointing at them —
  so anything that goes wrong leaves the file exactly where it was.

- **The sample shop now has colours on its spools and photographs on its
  finished jobs.** It had neither, so the two screens above opened on their
  empty states for anyone trying Khayt out — the matcher with nothing to rank,
  the portfolio with nothing to show. Both now demonstrate themselves.

- **The Mac app's *Best* report no longer prints `0.00 SAR` for a product
  nobody has finished.** That column counts every order and takes revenue only
  from the ones that completed, so a bracket quoted three times and never made
  read `0.00 SAR  3×` — which looks like three prints that earned nothing. It
  now shows a dash, the way the profit-and-loss column beside it already did.

- **The Mac app no longer writes English units into an Arabic screen.** Every
  card in the library said `printed 1×` in English whatever language the shop
  was in, and seven places wrote a bare `g` after a weight — the spool table,
  the product catalogue, the spool picker, a model's colours, a job's parts,
  the nozzle-wear bar and the import summary. Khayt has had words for both for
  years (`جم`, `طُبع 1 مرة`); the Mac app simply was not asking for them. The
  waste table also stopped writing "180 grams" in every row under a column
  already headed *Wasted weight (g)*.

- **Money and percentage fields on the Mac now say what unit they are in.**
  *Discount* on a new job is a percentage, and the box beside it said only
  "0" — so a shop knocking fifty riyals off a job would type 50 and take half
  the price off instead. *Target profit margin* now reads `%`, and *Shipping
  cost*, *Deposit / advance received*, *Amount paid*, an expense's *Amount*, a
  waste log's *Estimated cost*, *Minimum order amount* and *Default packaging
  cost* now show the currency, the same way a spool's cost and a machine's
  nozzle already did.

- **The Mac app no longer freezes solid while macOS asks about your Keychain.**
  The first time a new build reaches for a saved credential, macOS puts a
  permission dialog in front of it. The read was happening on the main thread,
  so the window drew nothing at all until somebody found the dialog: it looked
  hung rather than waiting. It now happens off the main thread, and the window
  stays alive.

- **The Mac app now sends what you change to Khayt Cloud on its own.** It used
  to send only when you opened *Check the cloud* and pressed *Send*, so an edit
  made on the Mac stayed on the Mac until somebody remembered — and two machines
  quietly drifting apart is the kind of problem you find out about a week later.
  It now pushes a few seconds after each change, retries on its own when the
  connection is bad, and the sidebar says what it is doing instead of always
  saying "Not synced automatically".

  It asks for your cloud passphrase **once per launch**, and then works in the
  background. The passphrase itself is still never stored anywhere — that is
  what keeps the cloud copy readable only by you — so opening the app on a new
  day means unlocking it once. *Lock Khayt Cloud* in the File menu takes it back
  whenever you want, and the sidebar shows "Cloud locked" until you unlock again.

- **Your storefront keeps quoting delivery dates when Khayt is closed on the
  Mac.** The date a storefront quotes comes from a snapshot Khayt publishes of
  its own queue, and it stops quoting once that snapshot goes stale — 24 hours,
  by default. Only the Electron app published it, so a Mac running the native
  app alone took the shop's delivery dates offline a day later, with nothing
  anywhere saying so. The Mac app now publishes it too, on the same six-hour
  cadence and from the same shared rules, so both apps make the same promise
  from the same book.

- **A printer that is mid-job now counts against what the Mac promises.** The
  Mac knew how long each print had left and was not passing the number to the
  part that works out capacity, so every busy machine was treated as "busy for
  an unknown time" and dropped out of the calculation — a shop with one printer
  running quoted as though it had none. On this shop's own book that was the
  difference between promising work could start today and promising tomorrow.

- **The Mac app says why the cloud is taking whole copies instead of just the
  changes.** Khayt Cloud stops sending a shop its changes one at a time as soon
  as one device signed in to that shop looks unable to read them — a machine on
  a Khayt older than 3.6, or one that signed in and has never synced. The Mac
  app already handled it correctly and said "the whole book was sent", but not
  why, so the state read as a fault and there was nothing to do about it. It now
  names the cause and the way out, which is the same gesture for both: open
  Khayt on every machine that uses the shop, update it, and let it sync once.

- **And macOS stops asking after every single update.** The dialog kept coming
  back because the Mac app was signed ad hoc, which is to say with no identity
  at all: what macOS remembers about such an app is its own content hash, so
  every rebuild was a different application and the permission granted to the
  last one was granted to nothing. The build now signs with a real certificate
  when the machine has one — a Developer ID for preference, an Apple Development
  certificate otherwise — and the identity macOS records is then the same on the
  next build and the next. Permission given once holds. A Mac with neither
  certificate still builds; it signs ad hoc as before and says so.

- **A shop's credentials never go to the cloud, and now that is a step rather
  than an accident.** The desktop's window is handed a store whose secrets are
  already replaced with a mask, so what it uploads has always carried masks. An
  app that reads the book straight from disk holds the real ones — so the Mac
  masks every credential itself before a whole store is sent. The field list is
  the same one that decides what is encrypted on disk, and a send refuses
  outright if that list is missing rather than going up unmasked.

- **The Mac app can send for a shop whose cloud will not take changes one at a
  time.** Khayt Cloud refuses a delta chain for a shop with any credential it
  cannot vouch for — including a token nobody has been seen using, which never
  expires and so never stops counting. For such a shop the Mac's send simply
  failed. It now does what the desktop does: merges the cloud's copy into this
  book first, then sends the whole book, with the revision guard making anything
  that arrives in between a refusal rather than an overwrite.

- **"A setting differs from the cloud's copy" was still wrong, for a second
  reason.** Khayt masks every credential before pushing a store, so the API key,
  the sync token and the print library's S3 secret are `__KHAYT_MASKED__` in the
  cloud and encrypted here. Compared as values, that made the warning true for
  ever for any shop that has configured anything at all. A masked field is now
  read as "the cloud does not carry this" rather than as a difference — checked
  against a real shop's live cloud, where all three of its differing settings
  keys differed only in a mask.

- **"Settings differ too" was telling every synced shop something untrue.** The
  desktop writes `settings.cloud.lastServerRev` after a successful push, so the
  copy that went up carries the previous value and the local one is permanently
  a step ahead. Compared plainly, that made "your settings differ" true for
  ever — and it appeared under a heading saying the two held the same records.
  The sync's own bookkeeping no longer counts as a settings change, and the
  wording no longer says "too" when nothing else differs.

- **The Mac app can bring the cloud's copy down.** *Check the cloud* has a
  second button beside sending, and between them the two directions mean a Mac
  and the cloud can be brought into step without opening Khayt. A backup is
  taken first, settings are never brought down, the ledgers are only added to,
  and a change made here that was discarded because the record had been deleted
  on another device is said on screen rather than swallowed.

- **Which collections a sync may only add to now lives in one place.** The
  list of ledgers — waste, maintenance, time entries, the audit log — sat in the
  desktop's settings file, so a second app could not merge without writing the
  rule again, and a ledger added on one side would have been silently
  overwritten on the other. The merge itself moved with it.

- **Three names in the Mac app's sidebar were cut off mid-word.** Khayt calls
  them "Expense Tracker", "Failed Prints & Waste Log" and "Profit & Loss by
  Quarter" — good names for a screen, too long for the column. Under a heading
  that already says "Money" they are Expenses, Waste and Profit & Loss, and the
  screens keep their full titles. A test now measures every sidebar name in both
  languages; Arabic is not the shorter one.

- **If the Mac app's shared rules fail to load, it now says so where the figures
  are.** It said it in one caption at the foot of the sidebar — the one place
  Apple's guidance says not to put critical information, because people move a
  window in a way that hides its bottom edge. Meanwhile every screen showed an
  empty dashboard and a blank profit and loss, which looks exactly like a quiet
  shop.

- **The Mac app's window has a floor.** There was no minimum size, so it could
  be dragged down until the jobs table's six columns — 644pt of minimums — were
  squeezed into each other.

- **There is a way to take a job that you can see.** The machines, spools,
  expenses and waste screens all had a "+" in the toolbar; the two holding the
  shop's actual work — the jobs table and the board — had none, so ⌘N and the
  File menu were the only ways in.

- **The Mac app can be driven from the keyboard.** ⌘F puts the caret in the
  search field, ⌥⌘I shows and hides the details pane, and Expenses, Waste and
  Reports are in the Go menu at last — the sidebar had always had them and the
  menu bar never did, so they had no keyboard route at all. Right-click works on
  the jobs and customers tables, which every other table already answered.

- **Space looks at a print file, the way it does in Finder.** ⌘Y as well, and a
  Quick Look item in the model's own menu. A library of print files you cannot
  look into without launching a slicer is a filing cabinet.

- **A customer written down as a name and nothing else showed an empty CLIENT
  heading.** A heading with nothing under it reads as a screen that failed to
  load. There are three states, not two — nobody has written them down, they
  are written down with a phone number, or they are written down and that is
  all — and the third had nowhere to go.

- **A white filament had no swatch at all.** The library outlined every colour
  in the hairline meant for sitting on the window background, which is visible
  around a black filament and invisible around a white one. On this shop's own
  four-colour helmet, three colours showed a square and the fourth showed a
  gap. Swatches are now outlined from their own colour — a dark line round a
  pale one, a pale line round a dark one — which is the only version that works
  in both themes and over a photograph.

- **"1 machines".** The Mac app's window counted things by putting a number in
  front of the plural, so a shop with one printer read "1 machines", one spool
  "1 spools", and a customer with one job "1 job" on one screen and "1 jobs" on
  another. There is one counting rule now, and a test that fails if a word is
  counted with and has no singular — because a missing one does not read as the
  plural, it reads as the key.

- **Three things the Mac app said awkwardly.** A part weighed "129.18 g",
  because the money formatter was being used for grams — two decimals of a gram
  is a precision no filament scale has. The job inspector labelled a row "paid"
  in lower case between "Total" and "Owed", because it borrowed Khayt's status
  word rather than using a label. And the window said "6 Filament" and
  "3 Machines", because the counts reused the sidebar's headings.

- **An invoice is addressed to the customer now, not to the job.** BILLED TO
  read `project` — the field the order editor calls "Description" and the print
  log calls "Project / Client" — so a job linked to a customer printed the
  job's name with that customer's own phone and email underneath it, on a tax
  document. It is now their name, read in the language the shop writes in, and
  the job moves to a *Project* line beside the invoice number so nothing is
  lost. A job with no customer prints exactly as it always did: nine of the ten
  invoice fixtures did not move by a byte.

- **Forty-five things the Mac app said only in English now speak Arabic too.**
  "No jobs yet", "Reveal in Finder", "Marked urgent", the whole grouping menu,
  every empty screen and every tooltip — all of them reached a shop running
  Khayt in Arabic exactly as written. There is now a test that fails on a
  string literal reaching a screen at all, because the last two of these were
  found in a photograph rather than by anything that runs.

- **Five lines in the Mac app's sidebar could still wrap, and a wrapping line
  there is what crashed it.** The guard written after that crash forbade asking
  for two lines; it said nothing about a label that asks for nothing, and
  SwiftUI wraps by default. Among them was the name of whichever app has the
  book open, which has no length limit at all.

- **A job taken on the Mac now records what it was priced at.** Khayt's own
  job editor reads a part's rates straight back into its form, so a part saved
  without them opened there with every rate field blank — and the next save
  re-costed the job at nothing. A job taken on the Mac would have lost its
  price on somebody else's machine, with neither app saying a word. The seven
  figures now travel with the part, exactly as the calculator writes them.

- **The Mac app was quoting jobs at a fifth of what they cost.** Everything but
  the filament — machine wear, electricity, labour and the allowance for prints
  that fail — was read from five settings Khayt has never written anywhere, so
  every one of them came out as nothing and the price was the material and no
  more. On a real 272-gram, fifteen-hour job that is 20.40 where Khayt's own
  calculator says 109.43. The rates now come from the figures that calculator
  opens on, a machine supplies its own power draw and wear, and the New Job
  sheet shows the four parts of the cost so a shop can see what is in the
  number — including when one of them is zero.

- **The Mac app's sidebar stopped claiming it cannot sync.** It said "Not
  synced from here" under a struck-through cloud, which became false the moment
  *Check the cloud* learned to send. It now says "Not synced automatically" —
  the true part, which is that nothing happens in the background and nothing
  comes down from the cloud at all.

- **The Mac app said money to a customer differently from the desktop.** A
  Telegram message about a finished job built its price by hand — the figure,
  a space, the currency code — instead of using the shop's own currency table.
  A shop in dollars was told "400.00 USD" by one app and "$ 400.00" by the
  other, about the same job. It now formats exactly as `renderer/currency.js`
  does, symbol on the side that currency puts it.

- **The Mac app's money figures have tests.** The reports tiles put four shared
  modules together in one expression, and every way of getting that wrong
  returns a perfectly valid answer full of zeros — which has happened twice.
  Revenue, cost, margin, average order and what is outstanding are now pinned
  against a book small enough to add up by hand, and the tests go red when the
  wiring is cut.

- **Why a product's price is what it is now comes from the rule that decides
  it.** The Mac's catalogue read `lib/product-price.js`'s answer and then
  worked out the explanation again in Swift. It agreed — and a rule written
  down twice is one that can stop agreeing later, with nobody watching the
  copy that drifts.

- **The Mac app can send what is only on this Mac to the cloud.** Until now
  *Check the cloud* could tell a shop the two were apart and could do nothing
  about it — the only way to close the gap was to open the Khayt app and let it
  sync. There is now a *Send what is only here* button beside the difference.
  It appends to the cloud's chain and never replaces it, and it goes one way
  only: a record the cloud has never seen, or one this Mac has edited more
  recently. Anything the cloud holds a newer copy of is left exactly as it is,
  because this app does not merge and pretending otherwise is how a shop loses
  work. Settings still need the Khayt app, and the screen says so rather than
  dropping them without a word.

- **The Mac app now tells the cloud it can read a delta chain, and this
  matters to every other device.** Khayt Cloud records what each credential is
  capable of, and one device it believes cannot fold a chain closes delta sync
  for the whole shop — every machine then uploads the entire store on each save
  instead of the handful of records that changed. *Check the cloud* said nothing,
  so it was counted as a device that could not, and the desktop only reopened
  the gate the next time it synced. It folds chains and now says so.

- **Installing the Mac app over a running copy is now refused.** The install
  step deleted the bundle and copied a new one in its place. A running app keeps
  the executable it launched with, so this never updated the app on screen — and
  it removed, from underneath it, every file it had not read yet: the business
  rules, the locale catalogues, the invoice stylesheet. The failure that follows
  looks like a bug in whatever the shop was doing at the time. It now stops and
  says to quit the app first (`--force` overrides), and says after any install
  that a running app must be reopened.

- **Check the cloud now shows its working.** Beside the cloud revision it says
  how many changes came after the base and how many of them were applied —
  because "19 jobs are newer here" means one thing if the chain was folded and
  something else entirely if it was not, and the answer alone cannot tell you
  which. Deletions are also counted properly now: a deletion's id is only unique
  within its own collection.

- **The Mac app shows the catalogue.** What the shop sells, with the price
  Khayt computes and — beside it — why that number: your own price, rounded, or
  calculated. Weight, materials and margin come from the product's own parts.
  The sidebar row appears only for a shop that has a catalogue; making and
  photographing products is still Khayt's.

- **The Mac app speaks to OctoPrint and PrusaLink printers too.** Three of the
  seven protocols now, up from one. Both send an API key, which the app opens at
  the moment it sends it and holds nowhere. Duet and Repetier still say plainly
  that this app does not poll them: both need a session handshake before the
  first read, and there is no machine here to answer one.

- **The Mac app can check the cloud.** *Book → Check the cloud* asks for your
  cloud passphrase, reads what Khayt Cloud holds and counts the difference —
  which records are only here, which are only there, and which are newer on each
  side. It reads: nothing is sent, merged or changed on either side, and the
  sheet says so before it asks for anything. The passphrase is used once and not
  kept, because Khayt stores it nowhere and that is what makes the cloud copy
  readable only by you.

- **Groundwork for cloud sync on the Mac.** The Mac app can now read what
  Khayt Cloud holds: scrypt, AES-256-GCM and gunzip, matching `sync-crypto.js`
  byte for byte. Nothing uses it yet and it cannot write — this is the piece
  that had to be proved correct before anything is allowed to depend on it.

- **The Mac app says that it does not sync yet.** If your book is connected to
  Khayt Cloud, the sidebar now says so plainly: changes made here reach the
  cloud when the Khayt app next runs on this Mac. It writes to the book and
  marks every change, which is what makes that sync pick them up — but a shop
  with two machines that stopped opening Khayt would have had the two drift
  apart with nothing said.

- **The sample shop has customers and a catalogue.** It always said who each
  job was for and what it was, in free-text fields — but with no customer or
  product records behind them, the Customers screen and the new Best page
  photographed empty and could not be judged. Thirty-one customers and twenty
  products, taken from the names the sample already carried.

- **The Mac app can read the printer's own job history.** Right-click a Klipper
  machine → *Read the printer's history*. The nozzle counter reads completed
  orders, and a machine runs far more than it sells — test prints, reprints,
  calibration. On the printer here that is the difference between nothing and
  6.4 kg since the nozzle went in, and the replacement warning was going to fire
  late, in the direction that ruins parts. The card now says where the figure
  came from.

- **The Mac app tells you when a print goes wrong.** A printer that faults or
  stops answering raises a macOS notification — the reason an app like this is
  worth leaving open. Khayt sends these to Telegram, email or a webhook, for
  somebody who is not in the workshop; this one is for the person who is, and it
  arrives whether or not the shop has ever set up a bot.

  The thresholds and the quiet periods are Khayt's own, so the two apps agree
  about what counts as trouble. A stall is not raised by default: a print that
  has not moved might just be a long layer. Everything raised is listed on the
  dashboard too, because a notification dismissed while you were making coffee
  is a notification you never had.

- **The Mac app can see what the printer is doing.** A machine card now shows
  the live state, the file, how far along, the time left and both
  temperatures — the one thing that needed the Electron app open. It reads
  only: no pause, no resume, no cancel, because a command sent to the wrong
  machine costs a print.

  Klipper (Moonraker) for now, and a machine on another protocol says so rather
  than showing an empty card. Only addresses on your own network are polled,
  and a printer that answers with a redirect is dropped rather than followed.
  The reading itself is the same code Khayt uses, including the two corrections
  a toolchanger needs: the temperature is the head that is actually printing,
  and the percentage is layers rather than file position.

  The dashboard carries it too — a line per running machine under the floor
  tiles, so "is it still going" does not mean changing screens. The Machines
  tile counts properly now as well: it reads what the printers said, and with
  nothing to read it had been counting every machine as neither live nor
  offline.

- **The Mac app shows who the shop's best customers are, and what it is asked
  for most.** A third page beside the P&L and the receivables, over whichever
  period you pick. Customers are ranked by what they actually paid; products by
  how often they were asked for, whatever became of the order — a part quoted
  twenty times and made twice belongs at the top of that list and nowhere on
  the other. Both rollups were written out four times inside the analytics
  screen and are now one shared module, so the two apps cannot disagree about
  who a shop's biggest customer is.

- **The Mac app prints the invoice.** ⌘P on a job, or *Invoice* beside the
  money in the inspector: the same document Khayt prints, saved as an A4 PDF.
  A registered shop gets its ZATCA QR; a shop missing a field the QR needs is
  told which, on the paper, rather than handed an empty box.

- **The Mac app sends the Telegram message.** A shop whose only integration is
  a Telegram bot can now finish a job on the Mac — before, the move was refused
  whole because the message could not be sent. It goes after the job is saved,
  and if it does not go out the shop is told rather than left to find out.

- **The Mac app can add and correct a printer.** Name it, pick a model to fill
  in its bed, colours, power and what its nozzle is made of, and record a
  nozzle change. Its connection settings and webcam are left to Khayt and
  carried through untouched.

- **The Mac app can correct the shelf.** Add a spool, fix a weight after a
  print ran long, change a price — with the price it used to be kept, so a
  supplier's invoice can be checked. Deleting one is undoable.

- **Back Up Now and Reveal Backups, in the Mac app's Book menu.** A backup on
  demand keeps the day's automatic one rather than replacing it, so both sides
  of whatever you are about to do survive.

- **The Mac app exports a copy of your book.** *Book → Export a Copy* writes
  the same `khayt-YYYY-MM-DD.json` Khayt writes, with the same redaction — API
  keys, passwords and access codes taken out, because this is the copy that
  leaves for an accountant or a support thread, not the backup that stays.

  It also masks anything still encrypted, whatever field it is in. The
  redaction knows the credentials it knows; that check knows what a secret
  looks like at rest, so a setting added tomorrow leaves as
  `__KHAYT_MASKED__` rather than as ciphertext.

- **The Mac app puts a backup back.** *Book → Restore from Backup* lists what
  is on the shelf, newest first, and says which copy was taken before an
  update. It refuses a file that is not a Khayt backup and a backup that is
  damaged, and it copies the book as it stands before replacing it — a restore
  you cannot undo is not one.

  What it carries forward is the part worth knowing about: Khayt builds its
  daily backup from the renderer's export, and the renderer never holds the
  shop's credentials (it sees `__KHAYT_MASKED__`) or the printer completion
  history (the main process owns it). Copying such a file over the book would
  have written the mask over every printer API key, LAN access code, the
  Telegram token and the cloud token, and deleted the completion history — with
  no symptom but printers that stopped answering. The restore merges them back
  from the book it is replacing, exactly as Khayt's own save path does, and it
  clears the retained cloud view so the next sync is a cold pull rather than a
  push of rolled-back records.

- **The Mac app keeps your daily backup.** Same folder, same names and same
  thirty-day history as Khayt's, so the two apps keep one set of backups
  between them — and a shop running only the Mac app is no longer one disk
  failure from losing its book. The sidebar says when the last one was taken.

- **The Mac app shows what the shop is owed, and since when.** Aged
  receivables beside the P&L: the four ages across the top, oldest first
  below. An instalment plan is aged by each payment's own due date, so a plan
  agreed months ago is not read as months overdue.

- **The Mac app shows profit and loss by quarter.** What each quarter earned,
  what it spent, the tax collected and what the shop kept — by the same rules
  the Khayt analytics screen uses, which now come from one place.

- **The Mac app tracks expenses and failed prints.** Two screens under Money,
  with a period to look at and a search that searches what is on them. Logging
  a failed print takes the filament off the shelf and remembers which spool, so
  deleting the entry puts it back.

- **The Mac app has a Settings window.** ⌘, — the shop's details, invoice and
  tax rules, bank details and accepted payments, operational defaults, and the
  language. Each pane saves only what it shows, by the same rules the Khayt
  Settings page saves through.

- **The shop's name on the Mac is the one its documents print.** It read a
  field nothing in Khayt writes, and would have issued a shop's invoice from
  "Khayt".

- **The Mac app can take a job.** ⌘N: what it is, who it is for, the parts and
  what they weigh, and the margin — and it prices them with the same arithmetic
  the calculator uses, because it is the same arithmetic. Save it as an order
  or as a quote. Picking a spool fills in what that filament cost, since the
  shelf already knows. It is the last thing a shop had to open the Electron app
  on a Mac to do.

- **The Mac app can fail a job's inspection.** Moving a job out of QC to
  anywhere but Completed asks what went wrong, and how much filament it cost —
  then sends it back to be printed again. Without it, a job dragged out of QC
  on the Mac was not counted as a failure: it was not counted at all, and the
  shop's pass rate quietly improved.

- **The Mac app can change a job's due date and how urgent it is.** ⇧⌘E. Two
  fields, because those are the two a shop floor actually adjusts — and the two
  whose changes Khayt writes into the job's edit history, so an edit made on
  the Mac leaves the same trace as one made in Khayt. "No due date" is an
  answer the sheet can give. Every other field the order editor writes is left
  exactly as it was.

- **The Mac app can record a payment.** ⇧⌘P, or the link under the money lines
  in the job panel: what was paid, how, and when. It cannot be more than the
  price — an overpayment is a credit note — and whether the job ends up paid,
  partly paid or unpaid is worked out by the same rule every report reads it
  with, so what is saved is what the next screen says. Clearing a payment puts
  the job back in what is owed. ⌘Z undoes either. A payment that would send a
  webhook or email a receipt is refused rather than half-made, the way a status
  change is.

- **The Mac app records that a job passed inspection.** Finishing a job that
  was in QC — by dragging it or from the Job menu — asks for the inspection
  note first, and writes the same record Khayt writes. Without it the job was
  not counted as a failure, it was not counted at all: a shop's pass rate is
  computed only over the jobs that carry a QC record, so completions made on
  the Mac would have quietly shrunk the figure they were measured against.

- **A job can be moved from the Mac app's jobs table, not only by dragging it
  on the board.** A new Job menu moves whatever is selected to any stage, and
  ⇧⌘H puts it on hold and asks why. The search box now filters the board too —
  it filtered every other screen, so typing a customer's name on the one screen
  where you are most likely to be hunting for a job did nothing at all.

- **The native Mac app's board can move a job.** Drag a card from one column to
  another and the job moves — stamping the completion, taking the filament and
  the packaging off the shelf, clearing a hold and pushing the due date out by
  the days it waited, all by the same rules Khayt uses, because it is the same
  code. ⌘Z puts it back, filament included. A move that would send a webhook,
  a Telegram message, an email or refresh a customer's tracking link is refused
  rather than half-made, and says which — those cannot be sent from the Mac app
  and cannot be sent afterwards, so the job stays where it is and the move is
  yours to make in Khayt.

- **What a finished job takes off the shelf is now decided in one place.** The
  grams it drew from each spool, the isopropyl and glue its print hours spent,
  the bolts a BOM assembly consumed, and the one-of-each packaging it ships in
  — all of it used to be readable only by the Electron window. Nothing about
  how you use Khayt changes; a job completed anywhere now empties the same
  shelf by the same arithmetic, including the parts that are easy to get
  subtly wrong: local stock before another branch, a chosen spool that has
  already run out, and a re-opened job never being charged twice.

- **The board marks the column with machines running in it, and the filament
  shelf shows colour.** On the Mac board the Printing column now carries the
  same amber the dashboard uses for work in progress, so the eye lands on what
  is on the machines — and only when there is something in it. The spool list
  shows each filament's colour beside its name, because a shelf is read by
  colour first; a spool with no colour recorded shows a dashed outline rather
  than something that could be mistaken for one.

- **The tax line in the Mac app is in Arabic when the app is.** The sidebar
  footer read the shop's tax name in Arabic followed by "included in the price"
  in English — the one sentence in the app that was welded together in code
  rather than written as a phrase, on a line that shows on every screen.

- **The Mac dashboard shows six months of takings, and says what they add up
  to.** Under the figures there is now a short chart of the last six complete
  months with a line above it in plain words — "Trending up — next month looks
  like 17,979 SAR, 78.3% above last", or which month was your best. Point at a
  bar and it tells you that month instead. The numbers come from the same
  calculation Khayt's own analytics screen draws, so the two agree. A shop
  without enough history to trend gets no chart rather than a flat line
  pretending to be a forecast.

- **The Mac app wears Khayt's own colours.** It was using whatever colours
  SwiftUI ships with, which meant the same orange marked a printer alert, a sync
  retrying and a warning that an edit had been overwritten — three different
  things, one colour — and a "done" green that did not match the one in Khayt.
  The app now uses the cyan from its own icon, keeps amber for the one thing the
  icon reserves it for (something being printed right now), and takes its
  green, amber and red straight from Khayt's own theme so a colour means the
  same in both apps. All of them are checked for legibility in light and dark.
  If you have picked an accent colour in System Settings, yours still wins.

- **And you can set your slicers up from the Mac app.** A new Settings pane
  lists them, marks the one models open in, and can find the ones already
  installed on the Mac so nobody has to type a path like
  `/Applications/Snapmaker Orca.app/Contents/MacOS/Snapmaker_Orca` into a
  field. A program that does not look like a slicer is refused when you pick
  it, not later when you try to print with it.

- **The Mac app opens a model in your slicer, by name.** The library's *Open*
  handed the file to macOS, which gives a `.3mf` to whatever is registered for
  it — often a viewer rather than the slicer you print from. The menu now offers
  your default slicer by name, with the others behind *Open in*, read from the
  same settings Khayt uses. It opens the app you already have running rather
  than starting a second copy of it.

- **You can add a model to the library from the Mac app.** ⇧⌘I, or *Add model*
  in the File menu: pick an STL, 3MF, OBJ or g-code file and Khayt copies it in,
  measures it, pulls out the preview and the filament colours a slicer left in
  it, and writes the entry — the same entry the other app would have written, in
  the same place. A file you already have is recognised and refused by name
  rather than added twice.

- **And it reads 3MF, which is what your library is made of.** The mesh inside a
  3MF is measured on the Mac exactly as Khayt measures it — checked by comparing
  against the models already in the library, where the answer matches to the
  triangle.

- **Khayt measures a model itself now, on the Mac.** Triangle count, volume and
  size come from reading the mesh rather than from asking a slicer, so adding a
  model to the library will not depend on which slicer is installed. Checked
  against PrusaSlicer on the same files: the same triangle count, and the same
  volume to within a thousandth of a percent.

### Fixed
- **Fixed: every invoice printed the shop's name where its tagline and footer
  belong.** The document asks its host for four fields — the business name, the
  address, the tagline and the footer. This app answered two of them and
  returned the NAME for the other two, so the name appeared twice at the top of
  every invoice and again at the bottom, and the tagline typed into Settings had
  never once reached a customer. Nothing was blank and nothing failed; it looked
  like a design. A field the shop has not filled in now prints nothing, which is
  what an empty field should do.

- **Fixed: a printer named after its model said so twice.** "Snapmaker U1" sat
  under "Snapmaker U1" on two machine cards out of three, because most shops
  call a printer what it is. The model line still earns its place when it says
  something the name does not — "Bambu X1C" is a Bambu Lab X1 Carbon.

- **Fixed: three numbers on the dashboard that could not all be right.** None
  of them was calculated wrongly. Each was correct over a different population,
  printed inches from the others, and the arithmetic a person does between them
  gave a fourth number the app never showed.

  "Printing 5" beside "Machines 0/3" — the second counts printers ANSWERING ON
  THE NETWORK, not machines with work on them, so a shop whose three printers
  are all busy and none of them networked read a flat contradiction under one
  heading. The tile says "Online" now, which is what the number is.

  Revenue 1,243.08, Jobs 4, Average job 621.54 — revenue, cost, margin, the
  average and on-time are all over COMPLETED jobs; the "Jobs" tile is over every
  job in the period. Dividing the first by the second gives 310.77. The revenue
  card now prints the count it actually divides by, so the average can be
  checked against the money it came from.

- **Fixed: the settings screenshots were photographs of the menu bar icon.** The
  snapshot harness found the Settings window by taking the first visible window
  that was not the shop's — and since the menu bar arrived, the status item has
  a window that is visible and is not the shop's. Six pictures of a 30×34 nozzle
  glyph, written without complaint, for as long as the menu bar has existed.
  It now requires a window big enough to be one somebody reads, and when it
  finds none it says which windows were open instead of failing quietly.


- **Two of ten models in one real library were filed under a picture of
  themselves from above.** Importing a 3MF took the largest `Metadata/*.png` in
  the archive, and a slicer writes several: the plate render, a small copy of it,
  an unlit version, a top-down plan view and a colour-coded mask it uses for
  hit-testing. On flat models the plan view compresses badly enough to be the
  biggest file — 111 KB against the plate's 56 KB — so the plan view won. The
  rule picks by name now, with the reason for every exclusion written next to it,
  and it is pinned by the real member lists out of those files.

- **When the Mac app crashes, it now reliably says why — and that is checked by
  crashing it.** macOS reports an uncaught Objective-C exception with a backtrace
  and no reason, so Khayt writes its own note beside the book. The app aborted on
  7 September and left no note, and the tests covering that note were green:
  every one of them wrote a file itself and read it back, so `LastWords` was
  never called by any of them. The test that replaces them launches the app,
  tells it to raise, and reads back what it left — and it was proved able to fail
  by removing the handler and watching it go red.

- **Two more Mac tests were reporting on something other than the app.** The
  scan that checks every counted word has a singular looked for `counting(`,
  which also matches the tail of `exportForAccounting(` — so it picked up
  whatever string literal happened to follow that call and demanded a plural
  for `Open` and for a sentence about the sample shop, neither of which is
  counted. And the check that no screen spells anything out in English was
  right about the one thing it caught: a snapshot fixture with an English job
  name in it, now a figure instead.

- **The Mac's profit-and-loss table stops spreading across a wide display.** A
  table hands its spare width to its columns, which on a desktop screen put a
  quarter's name and its net income fifteen hundred points apart — the two ends
  of a row somebody has to read as one line. The app's other three tables can
  afford that because they stripe their rows, and zebra is what carries an eye
  across a wide row; this is the only one with striping switched off, on purpose,
  because it holds one row per quarter and stripes down an empty window looked
  like a screen that had failed to load. So it had nothing to carry the eye and
  now simply does not spread: every column has a ceiling and the table ends where
  the figures do. A figure is no more readable at four hundred points than at a
  hundred and forty.

- **The Mac's dashboard uses a big display instead of sitting in the corner of
  one.** Its content is held to a readable column so that a job's name and how
  late it is are not a hand's width apart — and on a desktop display that left
  the whole dashboard in the left third with an empty field beside it, reading
  as a screen that had failed to draw its other half. Past 1800 points the
  screen becomes two columns: what the shop is doing and what wants a person on
  one side, how it is doing on the other. The width a desk display has is spent
  on showing more of the shop at once rather than on stretching the same rows
  wider, and on the sample book the whole dashboard now fits without scrolling.
  A laptop is unchanged — it is not a big display, it is a full one. Checked at
  1280, 1470, 1710, 2560 and 3008 points rather than reasoned about.

- **The Mac's working-hours row put every number beside the wrong day.** Seven
  weekday names with a figure under each — except each figure sat forty-four
  points to the right of the day it belonged to, so the row whose whole job is
  to say "eight hours on Monday" said it about a gap. The field's label was
  empty but still claimed the form's label column and pushed the field off its
  own centre.

- **Two section headers in Settings were the odd ones out.** Fifteen of them are
  Title Case and three were not; the two the Mac shows — Delivery Estimates and
  WIP Limits per Column — now match. The Electron page's own fallback text
  disagreed with the translation it falls back from, in both cases, which is how
  the same heading managed to be spelled two ways in one app.

- **The Mac's colours respond to Increase Contrast.** Apple asks for an
  increased-contrast variant of every custom colour alongside its light and dark
  ones, and Khayt's palette supplied only two of the three — so a shop that had
  turned the setting on got no more contrast from any status colour in the app.
  Each one is now strengthened toward the far end of the surface it sits on,
  taking the palette from roughly 5:1 to roughly 8:1 without moving a hue.

- **Two status colours had quietly fallen below the contrast the palette
  promises.** Giving cards a colour of their own changed the background half of
  every measurement in dark appearance, and nobody would have seen it: "late"
  landed at 4.25:1 and "worth reading" at 4.52 where text needs 4.5, against the
  4.68 and 4.98 documented. The dark surfaces moved down together to put them
  back at 4.63 and 4.92, and the palette now records which figure to re-check
  when either changes.

- **An aged-receivables figure was all but invisible on the Mac.** The 31-60 day
  bucket was drawn in SwiftUI's `.yellow` — `#FFCC00`, which measures **1.51:1
  against white** where text needs 4.5 — so on a light screen the money in that
  bucket was a pale smear. It was also a colour chosen at the call site rather
  than from the palette, which is the habit that made the palette necessary. It
  is the palette's amber now, at 5.29:1, shared with the 61-90 bucket: both mean
  "wants a person", and a fourth hue invented to keep two ages apart would be a
  colour standing for nothing.

- **The Mac's sidebar stops saying "Dashboard 0".** Every other count there is
  how many things a screen lists; that one is how much is wrong, and no news is
  not a quantity worth printing. It shows nothing when nothing needs a person —
  the same fault as the two below, found by looking at the running app rather
  than at a screenshot.

- **Colour Studio and Reports no longer show a "0" in the Mac's sidebar.**
  Neither is a list of anything — a quarter is not a thing a shop has a number
  of — and all three call sites said so in a comment while passing zero to a row
  that drew whatever it was given. A zero beside a screen's name reads as an
  empty screen, so both looked like features nobody had set up yet.

- **A dependency that could only ever have been undefined.** Developer tooling:
  modules that work in both Node and a browser fall back to a global when there
  is no `require`, and in Node that branch never runs — so a wrong name in it is
  invisible until something loads the file the other way. One had been waiting
  since it was written. A check now reads every such fallback and fails if the
  name is one nothing publishes.

- **Cost per kilo climbed as a spool emptied.** It divided the spool's price by
  the grams REMAINING, so a 1 kg roll bought at 75 read 150 half way down and
  375 with 200 g left — the figure that compares two suppliers, wrong on exactly
  the spool a shop is about to reorder. Khayt now records what a spool weighed
  when it arrived, and the rate is worked out from that. A spool bought before
  this shows what it cost instead: half the roll is gone and nothing wrote down
  how much there was, so the rate cannot be recovered and is not guessed at.

- **Four HueForge studio tests waited eighty milliseconds and then looked.**
  Developer tooling: they failed together on a machine that had a build running
  beside them and passed on every quiet run, which is a suite that teaches
  people to run it again rather than to read it. They wait for the thing now.

- **A text STL written on Windows was read as nothing at all.** Not a truncated
  model — nothing. In Swift a CR-LF is a single character, so splitting the file
  on "\n" found no line breaks in it, the whole mesh came back as one line, and
  no line began with "vertex". Fifteen of one shop's models measured as empty
  and drew as blank, and every one of them opens perfectly in an editor. CATIA
  and several CAD exporters write CR-LF as a matter of course.

- **"1 days late."** The Mac's dashboard said it to every shop with a job one
  day over. The count sits inside the sentence rather than in front of it —
  Arabic puts متأخر before the number — so the sentence itself now has a
  singular, in both languages.

- **The Mac's filament shelf no longer shows a cost-per-kilo that climbs as you
  print.** It was the spool's price divided by the grams REMAINING, so a 1 kg
  roll bought at 75 read 150 once it was half gone — and worst on the nearly
  empty spool the screen most wants you to look at. Neither book records what a
  spool originally weighed, so the true rate cannot be worked out; the card
  shows what the spool cost, which is a fact.

- **In Arabic, the arrow between the two spools in Colour Studio pointed the
  wrong way.** The pickers swap sides right-to-left, so a fixed right-pointing
  arrow said the gradient ran from the second colour to the first — the
  opposite of the swatches drawn directly beneath it. It is the same glyph in
  English, which is why only a photograph of the Arabic screen could find it.

- **The Mac screenshot runner followed the system appearance.** Developer
  tooling: after dark and light became separate runs, the light one set no
  appearance at all, so a Mac that switches itself at dusk made the same command
  write dark pictures under light names.

- **The telemetry consent smoke test waits for the thing, not for 700 ms.**
  Developer tooling: it slept a fixed interval and then looked, which is a race
  a busy CI runner loses — it failed once on "crash opt-in → events start
  queueing" and passed on a re-run, having never failed locally. It now polls,
  which is both faster in the normal case and honest in the abnormal one.

- **A gift card could be spent on money the customer did not owe.** Redeeming
  one worked out what an order still owed as price − paid − gift card, leaving
  the CREDIT NOTES out. On a 500 order carrying a 300 credit note that reads
  500 rather than 200, so redeeming a full card took 300 more off it than the
  order needed. The money on a card belongs to the customer, and they have no
  way to find a balance that was quietly taken off it. The question now goes to
  `KhaytOrderMoney`, where it has a single answer.

- **A print library that was quietly never backed up.** Backblaze shows its
  endpoint as `s3.us-west-001.backblazeb2.com` and the Region box asks for the
  part in the middle; paste the whole host in and the address that gets saved
  carries the suffix twice — `s3.s3.us-west-001.backblazeb2.com.backblazeb2.com`
  — which resolves to nothing. It saved with the bucket switched **on**, and
  nothing between the settings page and the first upload ever asked whether the
  address existed, so the library simply never synced and no screen said so.
  Khayt already recovered this when the settings page was saved, which never
  helped a shop that had no reason to reopen that tab. The address is now
  repaired where it is read, so a book already holding a broken one starts
  working on the next launch.

- **Models the Mac added to the library had a doubled dash in their id.** Khayt
  writes `PF-mtjwvj1w05A`; the Mac built `PF-` and then asked for an id that
  supplies its own dash, so it wrote `PF--mtjwvj1w05A` and named the file's
  folder in the shared vault to match. Nothing reads the shape, which is why it
  went unnoticed.

- **The Mac screenshot runner no longer aborts partway through.** It took its
  dark screenshots and then switched the app to light for the rest, and AppKit
  ends that switch by invalidating constraints from inside the draw it causes —
  an abort with no reason attached, three runs out of three. Dark and light are
  separate runs now (`KHAYT_SNAPSHOT_DARK=1` for the dark set), so no process
  ever changes appearance and neither can abort. Developer tooling only; the
  app itself was never affected.

- **Four settings the Mac app could not change, and the two rules it was not
  running.** *Monthly expense budgets* — the Spending screen has drawn a bar
  against them since it was built and there was nowhere to set one, so every
  shop was measured against zero. *Monthly revenue goal*, now with a bar under
  the dashboard's tiles. *Auto-flag overdue invoices* and *Auto-nudge expiring
  quotes*, which pick out what to chase — both are new lists on the dashboard,
  and both stay off until you switch them on.

- **Four things an Arabic shop saw that nobody had looked at.** The Mac app's
  right-to-left layout had never been photographed. The sidebar's footer — the
  backup date, the sync line, who has the book open — had nothing painted
  behind it, so the list scrolled under it and drew *People* and *Waste*
  straight through *Opened read-only*. "Khayt for Mac has this book open" was
  English on every screen, because the sentence was built inside the file lock,
  which has no language; the lock now hands back the facts and the window says
  them. The gram was abbreviated two different ways in Arabic, `غم` in one
  place and `جم` everywhere else. And *Edit Job* — in **English** as much as in
  Arabic — wrapped "Mark as priority / urgent" one or two characters to a line,
  seven lines tall, because the segmented control took the row and left the
  label about fifty points.

- **An Arabic invoice no longer prints the shop's phone number backwards.**
  `+966 50 000 0000` is digits, spaces and a plus sign, and not one character
  of it has a direction of its own — so inside the right-to-left document the
  runs were laid out right to left and the customer's copy read
  `0000 000 50 966+`. The same for the email, the CR and the VAT number, on the
  shop's line and the customer's. Each is now isolated from the direction
  around it. For shops that also print Arabic-Indic digits, the pass that
  swapped the numerals was replacing the whole contents of each element it
  touched, which flattened the address into one paragraph, dropped the
  currency's styling in the amount column — and undid the isolation above.

- **The Mac app's spool shelf now says what currency its Cost and Per kilo
  columns are in.** They were bare numbers, and the only currency on that
  screen was the *owed* badge, which is a different figure about different
  money.

- **Pasting a whole endpoint into the Region box now works instead of quietly
  building an address that does not exist.** Setting up cloud storage for the
  print library asks for one piece of your provider's endpoint — a region, an
  account id — and builds the rest. Paste the entire endpoint from the
  provider's dashboard into that box, as is easy to do, and Khayt built a
  doubled address like
  `https://s3.s3.us-west-001.backblazeb2.com.backblazeb2.com`, saved it, and
  said nothing. Nothing between that screen and the first upload ever checked,
  so the failure turned up much later as a storage error nobody could connect
  to a settings page closed months before. Khayt now recognises a pasted
  endpoint and takes the part it needs out of it.

- **A PIN set in an old version of Khayt is quietly re-secured the next time it
  is typed.** Khayt moved to a much stronger way of storing PINs and recovery
  codes a while ago, and new ones have used it since — but a PIN set before that
  kept its old form for ever. It still worked, so nothing looked wrong; the old
  form is weak enough that a four-digit PIN can be read straight back out of it,
  and that stored value travels in backups and through the cloud. Khayt already
  knew how to replace it and simply never did. Now, the first time the correct
  PIN or recovery code is entered — the only moment it can be done — the stored
  value is replaced with the strong form. Nothing to do, and nothing changes on
  screen. A wrong PIN replaces nothing.

- **The window now reports ZATCA invoices through the same rules the tests
  cover.** Khayt had two copies of four Phase 2 rules — which invoices may be
  reported, what counter value the next one gets, whether ZATCA accepted it, and
  the submission log. The tested copy was in `lib/`; the Electron window ran its
  own. They agreed, checked line by line, so no invoice was wrong — but an
  invoice counter that ZATCA requires to be unbroken should not depend on two
  copies staying in step by luck. There is one copy now, and the window and the
  main process also encode the invoice XML with the same function rather than
  with two that happened to produce the same bytes.

- **A slicer path from a restored backup or a cloud sync can no longer run
  something that is not a slicer.** Khayt launches the slicer you configured,
  and both its path and its arguments live in your settings — which travel in a
  backup and through the cloud. The check that decided whether a path was safe
  to launch listed programs to refuse (shells, Python, Node…), and that list can
  never be complete: `awk`, `find`, `xargs`, `make`, `git`, `busybox` and a
  dozen other ordinary programs each run whatever command their arguments say,
  and none of them is a shell. Khayt already had the better check — one that
  requires the program to look like a slicer — written, explained and tested,
  but nothing was calling it. It is now the check every path goes through, and
  the same one used to detect installed slicers, so what Khayt offers you and
  what Khayt is willing to run are one answer.

- **Check the cloud answered 404.** The shop id was being escaped into the
  address in a way Khayt Cloud has no route for — every id contains an
  underscore, and it was going up as `%5F`. It now builds the address exactly
  as the Khayt app does. The same mistake was in the Telegram and printer
  addresses and is fixed there too.

- **The Mac app could stop unexpectedly after a minute or two.** The sidebar's
  bottom strip had a line long enough to wrap, and the sidebar is a column you
  can drag — so the strip's height depended on the column's width, which is a
  loop AppKit ends by quitting. It only appeared for a book connected to Khayt
  Cloud, which is why it was never seen here. Every line in that strip is one
  line now, with the long text moved into its tooltip.

- **The app now says why it stopped.** macOS crash reports for this kind of
  fault carry a backtrace and no reason at all, which is what made the one above
  expensive to find. It writes `last-crash.txt` beside your book and tells you,
  once, the next time it opens.

- **The Mac app's dashboard never warned about a worn nozzle or a dead
  printer.** Both are things the attention engine reports only when it is given
  what it needs, and it was given neither: the nozzle rule wants the wear module
  and got a function, and a machine only counts as offline after three failed
  polls in a row — a count the Mac was not keeping. Neither failed; both were
  simply silent.

- **The Mac app said "11 late" and "2 late" at the same time.** The badges on
  the jobs table and the kanban cards — and the count beside OWED — called a job
  late if it was unpaid and past its date, which marked finished work and even
  quotes as late. The dashboard's Late tile asked the shared rule and said two.
  Everything asks the shared rule now.

- **The Mac app was short by a credit note and by a gift card.** "Owed" in the
  title bar, on the customers table, on the jobs table and on every kanban card
  was `price − paid` worked out in Swift, so a job with a 300 credit note
  against 1,000 read as 1,000 still owed — while the Receivables page, which
  asks the shared rule, said 700. It now asks the same rule everywhere.

- **The Mac app listed customers in the wrong language.** An Arabic shop saw
  "Tuwaiq Makerspace" on the Customers screen and "مساحة طويق للصناع" on the
  Best page — the same record, two screens, two names. The table spelled names
  itself, English first; it now asks the same reader every other screen asks.

- **Telegram messages from the Mac app never went out.** The bot token is
  encrypted in the store, the app read it raw, and Telegram was handed
  `__enc__…` as a token — so every shop with Telegram configured was told the
  message failed, every time, since the day it shipped. The token is now opened
  at the moment it is sent. macOS will ask once for access to the key Khayt
  keeps in your login Keychain; if you decline, the app says so plainly instead
  of failing with a bad token.

- **The OctoPrint and PrusaLink readings are testable at last.** Both were
  written inline in `main.js`, where nothing could call them and their only
  guard was a scan of that file's text. They now live in `lib/octoprint.js` and
  `lib/prusalink.js` and are driven with real per-endpoint payloads — the two
  behaviours that matter most among them: OctoPrint reading "Offline" from the
  job endpoint when the printer is switched off, and PrusaLink taking the
  filename from `/api/v1/job` because the status endpoint has never carried one.

- **Three credentials were missing from the export redactor.** The print
  library's S3 bucket secret and the two Google Drive tokens are on
  `lib/store-secret-paths.js` — encrypted at rest, masked on the way to the
  renderer — and were on neither of the export's two lists. In Khayt itself
  they came out masked by accident, because the renderer's copy of settings is
  already masked; anything building an export from the store on disk shipped
  the real values. A test now fails if any credential the at-rest layer knows
  about survives an export.

- **A shared export carried every order's access tokens.** `trackingToken` and
  `quoteApprovalToken` are capabilities, not data: the first opens an order's
  status page over LAN and is the `/p/<token>` segment of the customer portal,
  and the second approves a quote — which turns it into an order in the shop's
  book. They are now removed from the two payloads that leave the machine (the
  file *Export* writes and the iCloud copy) and kept in the ones that restore a
  shop (the daily backup and a named restore point). They are minted on demand,
  so an import re-mints; a shop that migrates by export republishes its portal
  links.


- **Your backups before an app update are kept properly.** They were counted
  as ordinary daily backups and survived only by accident of how the filenames
  sort — and meanwhile each one cost you a day of ordinary backup history.

- **Telegram notifications to a public channel now work.** A chat ID typed as
  `@yourchannel` had its name stripped away and the message went nowhere, with
  nothing said — for as long as the feature has existed. Both shapes Telegram
  accepts work now, a group's numeric ID and a channel's @username, and an ID
  that cannot work is refused when you type it instead of failing silently
  later.

- **Waste logged against a job takes its filament off the shelf too**, and off
  that job's own spools — not the first spool of that material, which charged
  the wrong roll for a shop with two of the same filament. Deleting the entry
  puts back exactly what it took, spool by spool.

- **A failed print now takes its filament off the shelf.** The waste log
  recorded the grams and their cost, and the stock was left untouched — so
  every failed print left the shelf reading higher than it really was, and the
  gap grew with every failure. The grams come off the spools the job was
  printing from, and the reprint still pays for its own. Where a printer
  measures what it got through before it stopped, that is the figure used;
  where none does, the shop types it, and the field now says so.

- **A quote you win by dragging its card now counts as won.** The acceptance
  date was written only by the Approve button, so a shop that moves a quote to
  Pending on the board — or on the Mac app — converted it without recording
  that it had, and the quote conversion rate on the analytics screen only ever
  fell. Both apps stamp it now, and a date already there is never overwritten.

- **Deleting a failed print you logged by hand now puts the filament back.**
  The waste form took the wasted grams off the spool, and the delete button
  read which spool to restore from a field the form never wrote — so every
  manual entry deleted left the shelf short. The entry now records the spool.

- **The Mac app did not know who your customers were.** It worked them out from
  the names written on jobs, so a customer you had entered but not yet given
  work to did not appear at all, and nobody's phone number, email or VAT number
  was shown anywhere. It reads your customer list now, shows what you recorded
  about each of them, and ⇧⌘N writes down a new one.

- **Five things Bed Ready was quietly missing.** The consumable list had no
  category filter and no reorder suggestions; a printer's live state was worked
  out by looking for the word "print" in whatever the machine reported, rather
  than by the rule that tells a missed poll apart from a real fault; and three
  of its dashboards fell back to guesses. None of it errored — each is read
  behind a guard, so the feature was simply not there. All five are workshop
  logic that had never been given a script tag.

- **Bed Ready's estimates never learned from its own prints.** It records what
  a print actually took, and it could recognise a model — but not the g-code
  sliced from that model, and it had no way to link the two. So the history it
  was collecting could never be used to sharpen the next estimate. Half of that
  feature had a script tag and half did not.

- **Bed Ready could not tell a printer that had moved from one that was off.**
  It scans the network for printers like Khayt does, and had no rule for
  matching a rediscovered machine back to a configured one — so a DHCP lease
  expiring overnight read as "offline", which is what it also says when a
  printer is switched off, and the two have completely different fixes.

- **A QC failure recorded in Bed Ready did not say how bad it was.** The defect
  it wrote carried no severity and no photo reference, and never recorded who
  inspected the job — so a failure logged there answered "how serious was
  this?" with nothing at all. Failing a job now writes the same three records
  everywhere it can be done: the fields the pass-rate figures count, the defect
  the analytics table is built from, and the waste row with what the scrapped
  print cost.

- **The Mac app filed every handed-over job under Completed.** In Khayt a
  delivered job is a completed one carrying the date it was handed over — the
  status deliberately does not move, because moving it would empty the very
  column the button feeds. That rule lived inside the board's own grouping loop,
  so nothing else could read it. It is shared now: the Mac app's board shows a
  delivered job as delivered, which is to say it leaves the board, and the Job
  menu can hand one over the way Khayt does.

- **Recording a payment could write a status the next screen disagreed with.**
  Whether an order counts as paid, partly paid or unpaid was worked out in
  three different places, and the one inside the payment dialog was the only
  one that did not know about credit notes. So a job that had been part-credited
  and then paid off was saved as "partial" and read back as "paid" by the row
  underneath it — and sat in receivables for money nobody owed. There is one
  rule now, and it is the one every report already used.

- **A job completed through QC never sent the notification a job completed
  through the column button does.** Passing inspection wrote the completion
  itself rather than going through the same rules as every other move, so the
  Telegram message a shop had configured for a finished job did not go, and
  nothing reached the team's activity log. Both now happen wherever the job was
  finished from.

- **The Mac app's menu bar was half in English for an Arabic shop, and one of
  its items had never said what it does.** Every menu is now in the shop's own
  language, including the menu names themselves. The Model menu's first item
  had been written to read "Add to Favourites" or "Remove from Favourites"
  depending on what was selected, and had in fact read "Favourite" — its
  no-selection placeholder — since the day it was added, because a menu item's
  text is fixed when the menu bar is built and cannot be changed afterwards. It
  says "Favourite" on purpose now, which is what it does.

- **Bed Ready's production queue now moves a job by the same rules Khayt does.**
  It had its own, close but not identical, and the differences were the kind
  nobody notices for months: finishing a job never fixed what it cost, so its
  margin was recomputed later at whatever filament prices happened to be
  current; a job sent round again could not deduct its filament a second time,
  so the shelf reported spools it had already used; and a job resuming from
  hold never got back the days it spent waiting, so it came back late through
  nobody's fault. All three are fixed by there being one set of rules instead
  of two. A finished job also stops carrying a running print timer.

- **A job put on hold now remembers when, and why.** The due date a held job
  gets back is counted from the moment it stopped, and until now only Khayt's
  own "Put on hold" button recorded that moment — a job held any other way came
  back with its original due date and nothing to explain why it was suddenly
  late. Putting a job on hold also goes through the same rules as every other
  move now, which fixes three things it used to skip: the print timer kept
  running, so a job held for a week reported a week of machine time nobody
  spent; the Telegram "notify on hold" setting never fired from the one button
  that puts a job on hold; and nothing was written to the team's activity log,
  so the status change a shop most often has to explain later was the one with
  no record. The Mac app asks for the reason when you drag a card onto On Hold,
  and takes no for an answer.

- **The Mac app's board left out the jobs somebody was waiting on.** A job on
  hold, in post-processing or in QC had no column, so it did not move to the
  end of the board — it disappeared from it, and a shop looking for its
  bottleneck found an empty gap where the bottleneck was. All seven stages work
  passes through are on the board now, in the order it passes through them, and
  anything the board still cannot place is counted out loud at the bottom
  rather than dropped.

- **Bed Ready's inventory could fail to draw.** A shared module the shelf now
  depends on was not loaded on Bed Ready's page, so its filament screen threw
  before it drew anything. Bed Ready's page is now checked for this on every
  build, as Khayt's already was — it is the fourth time a feature has gone
  silently missing because nothing loaded the file behind it.

- **The rules for moving a job between stages now live in one place.** What
  may move, and what moving it costs — stamping the completion, deducting the
  filament and the packaging, clearing a hold and pushing the due date out by
  the days it waited, fixing the cost the job will be judged on ever after,
  moving a customer up a tier — used to be readable only by the Electron
  window. The native Mac app could show you where work was piling up but could
  not let you move a card, because the only place that knew what moving a card
  means was code it does not run. Nothing about how you use Khayt changes; the
  two apps can no longer come to disagree about whether a job is finished.

- **Which settings count as secrets is now decided in one place.** Every
  credential Khayt stores — the cloud token, the AI key, the bucket and Drive
  keys, printer API keys, ZATCA IDs, BNPL and webhook secrets, the LAN PINs —
  is encrypted on disk, hidden behind dots on screen, and put back untouched
  when you save an unrelated setting. Those four things used to be four
  separate lists in the code, and a secret could be on three of them: the one
  that was missed either sat in the file in plain text, or got overwritten the
  next time you pressed Save. Nothing about how you use Khayt changes; there is
  simply no longer a way for a new setting to be protected in three ways out of
  four.

## [3.7.0-beta.25] - 2026-09-03

### Before you update

- **The box on a print file that said "Folder" now says "Group", and it means
  something on your catalogue too.** Nothing is re-filed and nothing is lost —
  whatever you had typed in there is exactly where it was, under a name that
  says what you were using it for. A group is a set that belongs together: the
  seven Saudi Kings, findable and offerable as one collection.

### Added

- **Offer a collection as one package.** A group with two or more products can
  be made a package in one press, from **🎁 Bundles** in the catalogue — and it
  then *follows the group*. File an eighth king into the Saudi Kings and he is
  in the package, with nothing to remember. Quoting it puts every member in the
  build in one tap. Packages you built by hand are untouched and keep working.
- **Work on many files at once.** Press **Select** in Print Files, tick what you
  want — or take everything a filter is showing in one press — and then group,
  categorise, tag or delete the lot together. What you have picked stays picked
  while you change the filter, so the way to handle a big set is to narrow to
  part of it, take that, narrow to the next part and take that too. Filing two
  hundred files one dialog at a time was not filing them.
- **A print can now be several files.** Spiderman is a head, two arms and a
  torso, and he is one thing you print — not four. Until now the library could
  only hold one file per entry, so a kit downloaded as twelve STLs became twelve
  rows with nothing tying them together. A print's files are now listed on its
  card, and **Open in slicer** opens all of them at once, in one slicer window,
  instead of whichever one happened to be first.
- **Add files to this print**, in a card's ⋯ menu. Files or a whole archive go
  into the print you are looking at, rather than making new entries beside it.
- **Which file a print is named for is yours to choose.** The first file added
  is the main one — the one whose picture, size and file type the card shows,
  and what *Convert* and *View in 3D* open. Any part can be made the main one,
  and the print is re-read so its time and weight describe the file it now says
  it is.

### Changed

- **Groups and categories, on your files and your products.** A library of
  hundreds needs two different questions answered: *what belongs with this*
  (the Saudi Kings) and *what is this* (a bust, a functional part). Both now
  exist on print files and on catalogue products, both filter with one press,
  and the two narrow together — "the busts in the Saudi Kings" is one click and
  then another. A name you have already used anywhere is offered as you type,
  and typing it in a different case joins what you have rather than starting a
  second copy of one collection.
- **Your storefront publishes the category you already set.** It read only the
  box inside the Storefront dialog, so a shop that had categorised its whole
  catalogue published a storefront where nothing had a category, and had to
  type it all again. Your product's own category is used unless you override it
  there — the same fix the price got. The group is published too, so a
  storefront can show a collection together.
- **Dropping in a zip now asks what it is.** An archive of twelve models is
  either twelve prints or one print in twelve pieces, and nothing inside it says
  which. It used to always make twelve entries; it now asks once — and asks once
  per drop, not once per archive.

### Fixed

- **A customer who already had their print saw a tracker saying nothing had
  started.** The public order-status page did not know about the "final checks"
  or "delivered" stages, so an order in either showed none of its five steps as
  reached — including one that had already been handed over. Both stages are now
  shown, and named properly instead of appearing as raw labels like "qc".

- **An invoice could carry a ZATCA QR code that scans and is not valid.** If you
  had turned on e-invoicing but not yet entered your VAT number or business
  name, Khayt still printed a QR — one with an empty field inside it. It reads
  on a scanner, so nothing looked wrong, and the invoice was not compliant.
  Khayt now refuses to print an incomplete code, tells you what is missing
  before you hand the invoice over, and says so on the document itself in your
  own language.

- **Sixty-five messages appeared in English whatever language you use.** Saving
  a calibration model, starting a shift, a rejected temperature, a failed
  export — and, worst of all, the warning that your data file could not be read
  — were all written into the app in English and never translated. They are now
  in all nine languages, and a check stops another being added.

- **An older Duet could show every print as finished.** On the pre-RRF-3
  interface, a job that was 5% done reported as 100% complete, and stayed there
  for the whole print. Progress is now read correctly whichever of the two forms
  the printer sends.

- **You can now see and remove the reviews on your storefront.** Anyone could
  leave one, every one counted toward the star rating shown to your customers,
  and Khayt showed you only the average — so a rating could fall with no way to
  see what was dragging it down and no way to remove anything. Settings →
  Storefront now lists your reviews, marks which came from a signed-in customer,
  and lets you delete one.
- **A model Khayt could not measure is no longer quoted as free.** A damaged or
  malformed 3D file could come through the estimator as zero grams and zero
  hours, and be marked as a sound estimate — including on the public quote page
  and the intake form your customers use. Khayt now says the figure cannot be
  trusted, which is what the warning was there for.

- **A shop with several printers could lose a finished job's real figures.** If
  enough machines were slow to answer — printers switched off overnight, say —
  one round of status checks took longer than the gap before the next one
  started, and the two overlapped. When that happened the moment a job finished
  could be missed, and with it the only record of what the print actually used.
  Only one round now runs at a time.

- **An order paid off through a payment plan now actually shows as settled.**
  With plans corrected to bill only what is outstanding, a job with a deposit
  would have gone on showing the deposit as still owed even after the customer
  had paid every instalment. Cash recorded outside the plan — a payment taken at
  the counter — is never overwritten either.
- **Khayt now tells you about two things in your existing data.** Payment plans
  written before the deposit fix ask for more than the order still owes, and are
  flagged rather than quietly rewritten, because the amounts may be something you
  agreed with the customer. And where a client had already spent more loyalty
  points than they had really earned, you are told, so you hear it before they
  ask.
- **The tax summary now suits the country you are actually in.** It called
  itself a GAZT VAT return and numbered its rows the way the Saudi form does,
  which was wrong for every other country Khayt supports — a shop in the UK,
  the US or Canada was handed someone else's form with their figures in it. It
  now uses your own tax's name, shows box numbers only where they are yours, and
  says plainly that it is a summary to copy onto whatever return you file. Shops
  whose prices exclude tax rather than include it are handled correctly.

- **Setting up cloud sync could leave your shop openable on one computer only.**
  If saving your sync key to the server failed — a dropped connection at the
  wrong moment — Khayt carried on and showed you a recovery key to write down,
  as though everything had worked. Another computer logging in would have found
  no key and been unable to open your shop at all. Khayt now checks that the key
  arrived, shows the recovery key only once it has, and tells you plainly if it
  has not. The same check was added to joining and leaving an organisation.
- **The save Khayt makes just before installing an update is now as safe as
  every other save.** It was written by a separate, weaker route that skipped
  the step forcing data onto the disk and kept no rollback copy — so a power cut
  during an install could have left the store empty or half-written, at the one
  moment the app cannot try again.
- **A deposit taken before a job was split is credited back to the work.** Jobs
  you split in an earlier version kept the deposit on the original entry, and
  once that entry correctly stopped counting, the money was credited to nothing —
  so Khayt would have shown the full amount as still owed. The deposit is moved
  onto the sub-orders it belongs to, once, the first time you open this version.

- **A payment plan asked for the deposit all over again.** Generating
  instalments split the order's full price, ignoring anything already paid — so
  a SAR 3,000 job with a SAR 1,000 deposit became three payments of SAR 1,000,
  billing the customer SAR 3,000 for SAR 2,000 of work. Plans are now built from
  what is actually outstanding, and an order that is already settled says so
  instead of offering to bill it again.
- **Loyalty points were awarded for sales that never happened.** A cancelled
  order, a print you had marked as not business, and an order you had refunded
  in full all still earned the customer points — the calculation looked only at
  whether the job was finished. A client with one real sale alongside those three
  was owed four times the points they had earned. Points now follow the money the
  shop actually kept, and a report of monthly margin no longer counts your
  personal prints either.

- Internal: one guard now names every new seam in this release and fails if
  nothing calls it, so a finished feature cannot ship switched off.

- **Splitting a job across machines billed it twice and lost the deposit.** The
  original job stayed on the books at its full price alongside the new
  sub-orders, so a SAR 3,000 job split in two showed SAR 5,000 owed when SAR
  2,000 was. Any deposit already taken stayed behind on the original, so each
  new sub-order started as though nothing had been paid and the customer was
  invoiced for the full amount again. The deposit and any credit notes now
  travel with the work, split the same way the price is.
- **A customer could get a copy of the reply you sent them.** An email address
  submitted through your intake form was put into the mail link exactly as
  typed, so an address with extra instructions hidden on the end could quietly
  add a second recipient to your own reply — and the compose window looked
  completely normal. Addresses are now encoded, everywhere Khayt opens mail.
- **A filament tag can no longer put its own buttons on the scan screen.** The
  temperatures and weights read from an NFC tag were trusted to be numbers; a
  specially made tag could put page content in their place. They are now checked
  and escaped.

- **What actually came off the printer was thrown away every time you saved.**
  Khayt records the real filament weight and print time of each finished job
  from the printer itself, and then deleted that record on the very next edit
  you made — so the figures were never there the next morning, and a job's
  actuals fell back to an estimate. The history is kept now.
- **The VAT return declared no VAT at all.** Boxes 1 to 3 read fields Khayt has
  never written to an order, so the VAT due always came out as zero and total
  sales were reported with the VAT still in them. On SAR 400,000 of sales at 15%
  the form said SAR 400,000 of sales and nothing owed, when SAR 52,173.92 was.
  Sales are now shown net and the VAT is worked out with the same arithmetic your
  invoices use. Box 7 is left blank with a note, because Khayt does not record
  VAT on expenses — put your own figure in before you file.

- **Two people using the shop at once could lose one of their entries.** If an
  order was logged on one phone while an expense, a spool update or a survey was
  being saved from another — or from the app itself — the second one could put
  the store back the way it was before the first, so a record that had just been
  confirmed simply was not there. Everything that writes over the LAN now takes
  its turn properly, so nothing arrives on top of work it never saw. This also
  stops a repeated Salla or Zid delivery creating the same order twice.

- **Your daily backup was switching itself off, silently, once your shop got
  big.** Khayt saves a store up to 50 MB, but the backup refused anything over
  20 MB — and so did the iCloud copy, the restore points, and the snapshot taken
  before an update. Every safety net went off at the same moment, at exactly the
  size where there is most to lose, and Settings went on showing a date under
  **Last backup** as though nothing had happened. All four now accept whatever
  the app is willing to save, and a backup that fails says so on the screen
  instead of leaving yesterday's date sitting there.
- **Recovering after a crash could hand you back a two-month-old shop, and call it
  a success.** If a save was ever interrupted, Khayt left a half-finished file
  behind and never cleaned it up — and when it later had to recover, it preferred
  that stale leftover over the good copy from your last save. It now takes
  whichever copy is genuinely newest. And when recovery does cost you your last
  save, it says so plainly instead of showing a green tick that read "Recovered
  your data", so you know to check your most recent work.
- **Cloud sync no longer overwrites your edit without telling you.** If another
  machine had changed the same client, order or spool more times than yours had,
  its version won and yours simply vanished — no message, nothing in the record.
  The version that wins is unchanged, because one of the two edits has to go, but
  Khayt now tells you which of your edits were replaced and by which record, so
  you can look again at anything you had just typed.

- **A downloaded print file can no longer put fake controls on its own card.** A
  G-code file carrying a specially made preview image could add a hidden button
  to the card Khayt drew for it, so an ordinary click on the picture ran
  something else — and the picture was saved with the entry and synced to your
  other machines. Previews are now checked properly instead of by their first
  few characters.
- **Quoting off a part-used spool no longer multiplies the material cost.** The
  calculator divided the spool's price by however many grams were LEFT on it
  instead of the spool's size, so the same 100 g part costed SAR 9 off a fresh
  kilo and SAR 36 off a quarter-full one — and SAR 180 off the last 50 g. Every
  other place in Khayt already used the spool size.
- **A rush fee no longer follows you into the next quote.** Every other money
  field is cleared after you log a job; the rush checkbox was not, so one rush
  job silently added its percentage to every quote after it.
- **Importing the wrong file no longer erases everything you have.** Choosing any
  `.json` that was not a Khayt export — a slicer profile, a settings file,
  anything — emptied every order, client, invoice, spool and print file, applied
  nothing in their place, and told you it had imported successfully. It now
  refuses a file that is not ours and leaves your data untouched.
- **Restoring a backup no longer deletes newer work on your other machine.** If
  you restore an older backup on one computer, the records created since were
  treated as deletions and removed everywhere else the next time it synced —
  silently, on both machines. A restore is now understood as choosing an older
  state, not as deleting the difference.
- **Settings said your data file had no size limit. It has one.** It reported
  "No size limit ✓" in green while the app refuses to save past 50 MB — the
  exact wall a shop with thousands of files was heading for. It now shows how
  full the file is and warns before saving stops, not after.
- **Bed Ready updates could never show the warning either.** Its releases were
  published with one fixed sentence instead of the notes, so a Bed Ready shop
  was asked to install a change nobody had shown it — for every release there
  has ever been.
- **The warning before a major update would not have appeared at all.** Khayt
  reads a release's notes from GitHub as a rendered page, not as the file we
  write, and the part that finds the changes you must accept could not read a
  point that ran over one line — so it found none, and the update would have
  offered itself with one press. Every change in this release's warning runs
  over one line. Also fixed: using **Check for updates** by hand skipped the
  warning entirely, and a failed download replaced it with a live *Retry*.
- **A downloaded model pack can no longer fill your disk.** An archive that
  understates how big its contents are was allowed through a size check that it
  cost nothing, then unpacked anyway — measured at 480 MB written from a 470 KB
  file, and far more from a larger one.
- **The catalogue's "Ungrouped" and "Uncategorised" chips do nothing no longer.**
  Same fault as the one in Print Files below: pressing them looked like showing
  everything, so there was no way to find the products you had not filed.
- **Catalogue filter chips now count what pressing them gives you**, instead of
  counting the whole catalogue while the grid narrows on three things at once.
  And pressing a lit chip clears the filter even when that product's own
  spelling of the name differs from the one on the bar.
- **A recurring-order reminder no longer shows `{name}` and `{days}` as text.**
  The heading and the sentence underneath were stored under the same name, so
  one quietly replaced the other — in every language.
- **Two machines stay in step while only one of them has updated.** If you run
  Khayt on a laptop and a workshop PC and update one first, renaming a group on
  the older one no longer goes unseen by the newer one, and using *Identify*
  there no longer drops the other files of a multi-part print. Sync replaces a
  whole record at a time, so the older build carries fields it does not
  understand — and it was winning arguments it should have lost.
- **The "Unfiled" chip in Print Files has never worked, and now does.** Pressing
  it looked like it showed everything, because the filter it set could never
  match — so there was no way to find the files you had not filed anywhere. The
  new "Uncategorised" chip had inherited the same fault before anyone saw it.
- **Adding a file to a print that has versions no longer loses it.** If a print
  had versions — which happens by itself once you convert one for another
  printer — then adding, removing or re-ordering its files and afterwards
  pressing a version chip put the old set of files back, and anything added
  since was gone from the entry.
- **Making a different file the main one now drops what the old one said.** A
  print whose main file was a colourful sliced 3MF kept showing that file's
  colours, swap count, print time and weight after you promoted a plain model
  inside it — the previous file's numbers under the new file's name.
- **A filter chip's number now tells you what pressing it gives you.** They
  counted your whole library while the grid narrows on four things at once, so
  with a category on, a group chip could say 7 and then show 2. Each bar counts
  against the others now, and a combination that would show you an empty grid is
  no longer offered.
- **A file that fails to import no longer abandons the rest of the drop.** One
  bad file in a folder or archive stopped everything after it, left the files
  already copied with no entry, and never cleaned up.
- **The selection bar now counts what the filter is showing.** Turn on Select,
  then narrow to a group, and it still said how many the *previous* filter had.
- **Buttons that cannot be pressed now look like it.** Only one in the whole app
  did: the Download button on the update screen, which stays off until you have
  read what is changing. Everywhere else a disabled button was the same colour
  as a working one and the cursor still promised it would do something — so
  *Add file* with no library folder set, or a bulk action with nothing selected,
  read as broken rather than unavailable.
- **The Print Files screen no longer freezes on a big library.** Every card in
  the library was drawn every time — on every filter you pressed, every file you
  starred, and every round of the preview move below. At three and a half
  thousand files that was about **seven tenths of a second of frozen window,
  every time**. A screenful is drawn now and the rest arrives as you scroll:
  the same work takes **28 ms**. Nothing is hidden — search and the filters
  still look through the whole library, and *Select all shown* still means every
  file that matches, not the ones on screen. The photo gallery is the same — and
  it matters more there, because each of those is a full photo rather than a
  small preview.
- **Moving your previews out of the data file now finishes on the first
  launch.** It did forty at a time, because drawing the screen after each round
  was so expensive — so a library of three and a half thousand needed **eighty-six
  launches**, and until it finished, the data file stayed too big to save. It
  takes about a second and a half now, in the background, and your library is
  safe to save again the same day you update. Measured end to end on 3,415
  files: every preview moved, verified on disk, none lost.
- **Fifty-nine buttons and messages were showing their own internal name.** Not
  English text — the literal `plib.unfiled`, on a chip in your library, in every
  language including English. The bar that filters by folder and tag, the batch
  converter's colour dialog, "Delivered", "Done", "Resent", and the hint inside
  the product name box. Every one is written properly now, in all nine
  languages, and Khayt will not build if another one appears.


## [3.7.0-beta.24] - 2026-09-02

### Before you update

- **Khayt will move your model previews out of its data file** and into the
  folders beside the models themselves. It happens a little at a time while you
  use the Print Files tab, and no preview is removed until its new copy has been
  written and read back. This is what lets a library grow past a few thousand
  files.
- **A file you converted for another printer now shows as a version of the
  print** rather than a separate row underneath it. Nothing is refiled and
  nothing is lost — the original stays the one on show.
- **The tags box now offers the tags you already use.** Typing a tag that
  exists in another spelling files it under the one you have, so "Resin" joins
  "resin" instead of starting a second tag.

### Changed

- **Your library can now hold thousands of files.** Previews were kept inside
  Khayt's data file, and a preview is about nine tenths of what a print file
  costs to store — so a library of five thousand simply stopped saving, and
  everything you did after that was lost when you next opened the app. Previews
  now live beside the model files they belong to. Ten thousand files take less
  space than a thousand did, and nothing you already have is touched until its
  new copy has been written and read back to prove it is there.

### Fixed

- **Search no longer stutters in a big library.** Every letter you typed redrew
  every card on the screen, so at a thousand files each keystroke cost about a
  twenty-fifth of a second and holding backspace redrew the whole library each
  time. Finding the files was never the slow part — that takes under a
  millisecond — so the screen now waits for you to stop typing.
- **Two files added at the same moment no longer overwrite each other.** Files
  in a print's folder were named by the millisecond they arrived, which is only
  unique if no two ever arrive together.

### Added

- **Your tags stay one tag.** The tags box was free text with nothing to guide
  it, so "resin" and "Resin" became two tags — and the filter bar showed two
  chips for one idea, each finding only some of your files. The tags you already
  use now sit beside the box: press one to add or remove it. Type a tag that
  already exists in another spelling and it files under the one you have. A tag
  that really is new is kept exactly as you typed it, so "ABS" and "PLA+" are
  safe.

- **An update that changes how you work now asks before it happens.** Khayt's
  update prompt could not tell you what was in a release — every release ever
  published carried the same one-line note, "See README for full release
  notes", so the dialog said "Release notes were not included with this update"
  and asked you to install something it could not describe. It shows the
  release's own notes now. And when a release moves something you use every
  day, it says so at the top in plain words and **the download stays locked
  until you tick that you have read it** — you can always choose Later. An
  ordinary release is unchanged and still installs on one press.

- **A print can have versions — big and small, coloured and plain.** These are
  the ones you print *instead of* each other, and each keeps its own print time
  and weight, so a small version is quoted as a small version. Pick one on the
  card and everything follows it. Files you have already converted for another
  printer become versions named after that printer, so nothing has to be filed
  again.

## [3.7.0-beta.23] - 2026-09-02

### Changed

- **The buttons on a print file are one tidy row instead of a block of ten.**
  A card carried up to ten buttons that wrapped onto two or three ragged lines,
  and because two cards rarely hold the same actions they wrapped at different
  points — so nothing lined up across the page and a card could end with a lone
  bin on a line of its own. Now every card reads the same: open it in your
  slicer, mark it printed or failed, and one **···** for the rest. Delete moved
  to the bottom of that menu, under a divider; it used to sit one button away
  from "Open in slicer".
- **The queue's view switch is one control that shows where you are.** It was a
  single button that renamed itself, reading "Board view" while you were looking
  at the list — so the word on it was the place you were going one moment and
  the place you were in the next. **List** and **Board** now sit together with
  the current one marked.
- **Pause production is quiet until production is actually paused.** A button
  that is red all day is a red button nobody reads.
- **The same tidy-up across clients, the waiting list, quotes, products, the
  converter and Bed Ready's queue.** Bed Ready's toolbar had nine buttons and no
  "more" button at all. Everywhere a **Delete** or **Reject** used to sit beside
  the button you were reaching for, it now sits under a divider in the menu.
- **Icons are drawn, not typed.** Screens were showing emoji, which arrive in
  whatever colour and shape each computer decides — the print library, the
  queue, the catalogue, the converter and the order board all did. They use
  Khayt's own line icons now, the ones the rest of the app already used.

### Fixed

- **Forty pieces of the app were still in English in German, Spanish, French and
  Chinese.** The whole CSV import dialog, the resin calculator's fields, the
  order status page and the waste report had never been translated — they had
  simply been copied across from English, so every check that counts
  translations said they were done. They are translated now, along with three
  more in Arabic, Japanese and French.
- **A button no longer gains or loses its "+" depending on the language.**
  Buttons like "+ Add photo" and "+ Add location" carry that mark in the text
  itself, and eight of them had lost it in some languages.
- **An icon no longer sits flush against the words next to it** — the print
  history line read "printed3x printed". In Arabic the gap was on the wrong side
  of the glyph entirely.
- **A big print file can be added again, and it is measured.** Adding a file
  larger than about 50 MB left it in your library with no print time, no weight,
  no material and no picture — and said nothing, so the import looked like it
  had worked. Four different size limits were governing the same act of reading
  one file, and past any of them the answer was silence. Reading was also
  costing about six times the file's own size in memory, because the reader
  built a list of every triangle even when all it was asked for was the volume
  and the bounding box: a 250 MB model needed 1.5 GB and a second and a half. It
  now needs a fifth of a second, and the figures are identical to the last
  digit. **You can add a model up to 1 GB**, and an STL is measured from the
  file on disk instead of being copied whole into the interface first.
- **A big 3MF is measured instead of being given up on.** Working out a 3MF's
  size and volume used to build every surface in it twice over, so a poster or a
  kit — the files that are actually 200 MB — wanted six to twelve gigabytes of
  memory and never finished. Khayt now adds each surface up as it reads it: the
  same numbers to the last digit, a few hundred megabytes instead of gigabytes,
  and it happens outside the window so the app keeps drawing while it works.
- **Too big to draw is no longer treated as too big to read.** Only the preview
  picture and the overhang report need every triangle; print time, weight,
  material, volume and size do not. Past 150 MB a model still gets all of those
  — it simply does not get a picture, and tells you that rather than leaving you
  to find the blanks. If a file genuinely cannot be read, it is still added to
  your library and you are told the figures need typing in — in your own
  language, not English.

## [3.7.0-beta.22] - 2026-09-01

### Fixed

- **A photo too big for the cloud is no longer sent and lost.** The cloud stores
  one picture up to a fixed size and quietly drops anything larger — so a
  publish reported success and the picture was simply missing. The app now sends
  the smaller version instead of a picture that cannot arrive, and the cloud's
  limit has been raised so a real photograph fits either way. **Republish to get
  your pictures back.**
- **A published listing no longer sends its main photo twice.** The storefront
  needs a `photo` field as well as the gallery, and it was being uploaded a
  second time rather than worked out at the other end — half a publish, for
  nothing, and it was not counted against the size limit that decides how many
  pictures a catalogue can carry.

## [3.7.0-beta.21] - 2026-09-01

### Added

- **Your catalogue now publishes print time, weight and material.** Khayt has
  always known all three — print hours are what work out when a job can start —
  but a storefront never saw them, so you typed each one again into its admin. A
  number typed twice drifts, and then two places both look right. They travel
  with a publish now, and a product with no parts publishes nothing for them
  rather than a zero that would read as "prints instantly".

### Fixed

- **Storefront photos are published at a size worth looking at.** A published
  picture was the 240px thumbnail Khayt makes for the product grid — and that
  was also the main image on the storefront's product page, where a print
  deserves better. The full picture had been saved on your machine all along and
  nothing ever read it back; now it does. If a catalogue with a lot of photos
  does not fit, pictures get smaller before any of them are dropped.

## [3.7.0-beta.20] - 2026-09-01

### Fixed

- **The Medusa subscriber Khayt gives you now sends the material.** It asked only
  for the line item, and material lives on the product — so it arrived empty on
  every order request, with nothing to show that anything was missing. It also
  carries a link straight back to the order in your Medusa admin, if you set
  `MEDUSA_ADMIN_URL`.
- **A failed import is now retried instead of only logged.** The subscriber used
  to swallow failures, because a retry could once have filed a second order
  request. It cannot any more — Khayt Cloud recognises a repeat and answers it —
  so a delivery that fails keeps being tried until it lands.

## [3.7.0-beta.19] - 2026-09-01

### Added

- **Give your shop a web address people can read.** Settings → Online → Khayt
  Cloud now has a *Public web address* field, so your storefront can live at
  `/shop/your-shop-name` instead of a long id. Your original link never stops
  working, and if you change the name the old one keeps working for 90 days.

## [3.7.0-beta.18] - 2026-08-31

### Security

- **A printer camera can no longer inject code into Khayt.** A device answering
  your printer's snapshot URL could send a crafted content type that escaped the
  image tag and ran script inside the app. It needed something on your own
  network answering at the printer's address — a compromised printer, or anything
  able to take that address. The camera reply is now checked against the exact
  image types a camera sends, at both ends.

### Added

- **Publish your catalogue from the catalogue.** A ☁ Publish button sits in the
  Product Catalog toolbar. It was reachable only from Settings → Advanced →
  Automation → Khayt Cloud, four levels away from the screen you are looking at.
- **Sync your print library from the library.** A ☁ Sync button in the print-file
  toolbar pushes to Khayt Cloud now instead of waiting for the next automatic
  sync. Both buttons appear only when cloud is connected.

### Changed

- **Khayt Cloud and Storefronts & Payments now live under Settings → Online**,
  where you would look for them. "Online" previously held only local-network
  features while Khayt Cloud sat under "Automation". Who can see them is
  unchanged.

### Fixed

- **The last English text in the interface is translated.** "Board view", "Save
  filter", the work-in-progress limit labels and the post-processing preset
  fields stayed English in every language.
- **The default working week is Sunday to Thursday, five days.** It was Monday to
  Thursday — four days, matching no working week anywhere: the Gulf works Sunday
  to Thursday and most of Europe and the Americas work Monday to Friday. Due
  dates, machine queue estimates and the schedule were all worked out against a
  day less than a shop actually has. If you have already set your own hours,
  nothing changes.
- **Day names in Working Hours are translated.** Mon–Sun were English in every
  language.
- **A product description you type is saved.** It was silently discarded on every
  save, in every shop — the box accepted the text and the product kept nothing.
  Anything you wrote before this is still on the product and now appears in the
  editor again.
- **Shops writing a language other than English or Arabic can use the catalogue
  at all.** Product names were dropped the same way descriptions were, and the
  save refused outright with "Give the product a name first" even when the name
  was filled in — so the product editor did not work in seven of the nine
  languages Khayt offers.

## [3.7.0-beta.17] - 2026-08-31

### Added

- **Mark a print as not business.** A calibration cube, a gift, a bracket for
  your own shelf — tick the box in the order editor and it stays out of revenue,
  order counts and every report. It still counts towards nozzle wear and still
  occupies the machine, because it really printed.
- **The sidebar shows your business name** instead of the name of whichever
  theme you have active. The theme is still named in Settings, where you choose
  it.
- **The machines page shows what each printer is actually doing.** It had no live
  state at all — every figure on the card came from your order book, so a printer
  running a job you sent straight from your slicer looked like it had nothing on.
  Khayt was already asking that printer every thirty seconds.
- **Round your catalogue prices, or just type the one you want.** A calculated
  price of 43.71 is not a price anyone puts on a shelf. Set a rounding step —
  fives, tens, halves — and whether to go up, down or to the nearest, or type a
  price of your own that overrides all of it. The calculated figure stays on
  screen beside it, because that is the number that tells you the margin is
  working.

### Fixed

- **Cancelled orders no longer count towards your on-time delivery rate.** A
  voided job counted for or against your delivery record like any other. Prints
  you have marked as not business are left out of it too — a calibration cube is
  not a promise to a customer.
- **Entering your business name updates the sidebar straight away.** It only
  changed after switching theme or restarting.
- **The sidebar shows the Khayt wordmark again until you have actually entered a
  business name.** A shop that had never opened Settings saw "KHAYT" in place of
  it, which is the product's name rather than the shop's. Your own name is shown
  exactly as you typed it, not forced into capitals.
- **Hover descriptions appear when you hover.** Icon-only buttons relied on the
  browser's own tooltip, which waits about a second before showing anything and
  never shows on keyboard focus at all. They now appear promptly, and keyboard
  users get them too.
- **An empty print-file preview says why it is empty.** Khayt shows the preview
  your slicer embedded in the file; it does not render the model itself. A record
  imported from your printer's job history has no file on this computer at all,
  so there is nothing to show — and it now says so instead of showing a bare box.
- **Publishing a storefront uses the prices you already set in the catalogue.**
  It read only the price box on the storefront form, so a shop that had priced
  every product — cost, margin, rounding and all — published a storefront where
  everything cost nothing, and had to type it all again. The storefront box is
  now an override for the few items you want priced differently; leave it empty
  and the catalogue price is used. Product feeds are built from the same payload,
  so they were blank too.
- **A printer that is printing no longer counts as free capacity.** Lead times
  quoted to customers were worked out from your order book alone, so a machine
  five hours into a job was treated as available. Where the printer can say how
  long it has left, that time now counts; where it cannot, the machine is left
  out of the promise rather than assumed idle.
- **A printer nobody has heard from is no longer shown as idle.** "Not answering"
  and "free right now" looked identical, which is the wrong one to guess when
  you are deciding whether a bed is available.
- **Linking a print file to a catalogue part fills in the weight and print time.**
  It recorded the link and left both at zero, which looks exactly like zeros
  somebody typed — the numbers were behind a separate button. Anything you have
  already filled in yourself is kept: a weight you put on a scale is never
  replaced by the slicer's estimate.

## [3.7.0-beta.16] - 2026-08-31

### Added

- **Right-click works.** Misspelled words offer corrections and "Add to
  dictionary", and Cut, Copy, Paste and Select All are there — on Windows and
  Linux, right-click is how people copy text and Khayt had no menu at all. The
  menu is in your language.
- **The spellchecker follows the app, not your operating system.** It used to
  check everything against English whatever you were writing; there is no Arabic
  dictionary available, so for Arabic it now stays quiet rather than underlining
  every correct word. (On macOS the system spellchecker is used, which handles
  Arabic itself.)
- **You choose which languages you write in** — one or two, and which ones,
  from the nine Khayt speaks. Settings → Preferences → *Product languages*.
  Product names and descriptions, your business name, tagline, address, invoice
  footer and terms all get a field for each. A Turkish or German shop can
  finally enter its own language — before this the interface translated for it
  and the invoice a customer received had a blank where the business name goes —
  and a shop selling only in Arabic is no longer shown English boxes it has to
  leave blank.
- **Descriptions are per language.** A product could have a name in two
  languages and only one description — the paragraph a customer actually reads
  to decide. Existing descriptions are kept and moved into your first language.
- **Your online shop shows the languages you write in.** Publishing a catalogue
  now tells the storefront which languages it is written in, so a shop writing
  German and French is read in German and French. The public page could show
  English or Arabic and nothing else, so half of what those shops published was
  invisible to their own customers. Listings also show up to three photos, and
  one labelled as the actual printed part is captioned that way — republish your
  catalogue to pick this up.

### Fixed

- **Your address appears on ZATCA e-invoices again.** Every Phase-2 invoice was
  submitted with the seller's street blank, and the customer portal's printable
  copy showed no address either — all three read a settings field that has never
  existed. They now read the address you actually entered.
- **An order raised on your phone is numbered like one raised at the desk.** It
  used a prefix setting that was never saved anywhere, so it always came out as
  `ORD-…` and ignored the prefix you had set.
- **Customers are greeted by name in campaigns and reminders.** If you write in
  a language other than English or Arabic, the `{{name}}` merge field and the
  waiting-list reminder came out blank — so a campaign went to your whole client
  list opening "Hi ,". Client names were also missing from the kiosk view, order
  documents and the waiting list, and typing an existing client's name offered
  to create a second copy of them instead of finding the one you had.
- **Publishing a catalogue with a lot of photos works again.** A shop with
  roughly fourteen or more photo-rich products was refused outright — the whole
  catalogue, because of the pictures on part of it. Khayt now trims to fit,
  taking spare photos before any listing's only one, so the storefront publishes
  with fewer pictures instead of not at all.
- **The phone, the quote link and the recovery file know your business name.**
  They read English-or-Arabic directly, so a shop writing Turkish or German got
  a quote page headed "Khayt", a recovery code file that named no business, and
  client names missing on the companion app. All three now use the languages you
  chose.
- **The second name under a product or client shows your other language.** If
  you write in German and French, the line under every product name and every
  client row was blank — it was picking between English and Arabic, and Arabic
  is a field you have never filled in. It now shows whichever of your two
  languages isn't already on the line above, and nothing at all if you write in
  only one.
- Importing a printer's job history no longer stops if the printer sends back a
  malformed entry.
- **Icon-only buttons say what they do when you hover them.** Fifty of them
  announced themselves to a screen reader and showed nothing to everyone else.

## [3.7.0-beta.15] - 2026-08-30

### Fixed

- **An overdue nozzle now shows on the dashboard.** The warning existed on the
  machine card and on no dashboard at all: every theme draws its own, and none
  of them rendered the maintenance list it lived in. It reaches the attention
  bar on every theme that has one.
- **The Meridian dashboard's attention bar works.** It called a function that
  does not exist, so it had shown "All clear" since the day it shipped —
  through offline printers and late orders alike.
- **A nozzle threshold you have set is never changed for you.** Picking a
  printer model, or changing which nozzle is fitted, could overwrite the figure
  you chose whenever it happened to match one of Khayt's own suggestions — and
  plenty of deliberate figures do. Khayt now only fills the box in when it is
  empty, and suggests rather than rewrites.

### Added

- The machine card shows what the catalogue knows about your printer — hotend
  and bed maxima, chamber, toolheads, screen and XY pixel size for resin — and
  **a link to that printer's support page.**

### Fixed

- **Several photos on one product are now several files.** Every picture on a
  product was being written to the same filename, so only the last one survived
  and removing any of them would have taken the others with it. Products saved
  with one picture are unaffected.

### Fixed

- **The catalogue accepts photos again.** Picking an image did nothing at all —
  no error, no photo. Introduced in 3.7.0-beta.14 with the multi-image editor.

## [3.7.0-beta.14] - 2026-08-30

### Added

- **Klipper and Moonraker printers can hand Khayt their own job history.** A
  printer runs far more than orders — test prints, reprints, calibration, work
  nobody paid for — and all of it is real filament through the same nozzle. The
  button on the machine card reads that history and uses it for nozzle wear,
  which it is a better answer for than the order log. Reading is a single GET, so
  it is safe to run while the printer is mid-job.

### Added

- **A product can hold several photos, and each one says what it is** — a render,
  the actual printed part, a detail, a scale shot, packaging. The question a
  customer is really asking of a listing is whether that is a render or what
  arrives, and getting it wrong is a refund. The catalogue marks listings that
  have no photo of the real thing, and the storefront publishes up to three.
- **A catalogue part can be linked to a print file and filled in from it**:
  weight and time from the slicer, material and layer height from the setup you
  have had most success with. It tells you what it could not fill rather than
  leaving zeros that look typed.

### Fixed

- A print file recorded from a printer's own history, rather than imported, no
  longer stops partway through being read.

### Fixed

- **The nozzle replacement warning now counts what you have actually printed.**
  It read a field a part does not have, so it counted nothing and the warning
  had never appeared for anyone. On a real shop's data it read 0 g where the
  true figure was 2,461 g, past a 2,000 g threshold. It now counts print plus
  support, times quantity, on completed jobs since the nozzle went in.

### Added

- **Nozzle life now depends on the nozzle.** Brass, stainless, hardened steel,
  ruby and tungsten carbide have very different lives and Khayt used one figure
  for all of them. Every figure comes from a published test and says which one —
  see Settings → Printers → *Nozzle wear reference*, where you can replace any
  of it with your own numbers, and [docs/NOZZLE-WEAR.md](./docs/NOZZLE-WEAR.md)
  for the readings behind them. The four figures that are still estimates say so.
- **Abrasive filament counts for more.** 300 g of carbon-fibre PLA costs a brass
  nozzle far more than 300 g of plain PLA, and the counter now reflects that.
  Glow-in-the-dark is included but rated mild — a controlled test measured no
  wear from it at all, which is the opposite of its reputation.
- **The printer catalogue knows more, for 39 of its 49 printers**: what nozzle it
  ships with, maximum hotend and bed temperature, whether the chamber is heated,
  filament diameter, and a support link that was checked to resolve. Picking your
  model fills all of it in, and every field stays editable.
- Toolchangers, IDEX and multi-material machines are described as such. A
  Snapmaker U1 was recorded as a plain direct-drive printer, and so was a
  five-toolhead Prusa XL.
- Resin printers are described as resin printers — screen size, resolution and
  XY pixel size, instead of a nozzle diameter of zero.

## [3.7.0-beta.13] - 2026-08-29

### Fixed

- **Signing in to Khayt Cloud no longer sticks on "Connecting…".** Logging in,
  creating an account and joining a team all reached the server, got a valid
  answer, and then stopped one line later on an internal error that nothing
  reported. Nothing was saved and nothing was shown, so the only symptom was a
  panel that never finished. All three now complete.
- **Saving Settings no longer signs you out of Khayt Cloud.** Entering a
  business name or a logo rebuilt your settings from the form and dropped
  everything the form does not show — your cloud account among them, along with
  your slicer setup and your privacy choices. Settings the page does not display
  are now carried through untouched.
- **The "Email not verified" warning no longer appears for accounts that are
  verified.** Khayt asked the server on every sign-in and then discarded the
  answer, so every device started out believing your email was unverified.
- **When a self-hosted server has no email set up, sign-up says so** instead of
  asking for a verification code that was never sent.
- **An action that fails now says so.** When something goes wrong mid-way, Khayt
  tells you rather than leaving the screen mid-flight — including during start-up,
  which previously had no reporting at all.
- Clicking **Restore** on a deposit the audit can no longer find refreshes the
  banner instead of doing nothing.

## [3.7.0-beta.12] - 2026-08-29

### Fixed

- **Creating a Khayt Cloud account now asks for the verification code it just
  emailed you.** The code was sent, and the only place to type it was a small
  "Verify email" button in Settings → Khayt Cloud — a panel you had just
  finished with. Khayt now asks for the code straight after you have saved your
  recovery key. The button stays, for when the email takes a few minutes or you
  close the box.

## [3.7.0-beta.11] - 2026-08-29

### Fixed

- **Delivery estimates were two days later than they needed to be, per week of
  work.** The calculation counted a full seven days for every working week
  including the last one, so five days' work was quoted as a week and two weeks
  as sixteen days. Erring late is what the safety margin is for — a number you
  choose and can see — and the arithmetic should not have been adding to it
  quietly.

### Added

- **Images can be fitted to an upload's size limit before the upload fails.**
  Storefronts cap what they accept — Medusa allows 1 MB per image — and a
  rejected picture is normally discovered at the end of making a listing, after
  everything else is written. Khayt can now take a photo and produce a version
  that will be accepted.

  It tries the least damaging thing first: an image already small enough is left
  exactly as it is, then quality is reduced before any size is, and a picture
  with a transparent background stays a PNG for as long as that is possible. If
  it cannot get under the limit without ruining the picture it says so instead —
  you can crop or re-shoot, but you cannot undo a photo that was quietly
  flattened.

  It always says what it did: converted, resized, recompressed, and from what
  size to what size.


- **Khayt can tell a customer when their order would actually be ready.**
  Settings now has **Delivery estimates**: how many printing hours you get
  through on a working day, how many days a week you work, and how long
  finishing, packing and a safety margin take. From those and the jobs already in
  your queue, Khayt works out when a new order could be printed, finished and
  posted.

  The safety margin is added to what a customer is told and to nothing else —
  your own schedule board keeps showing your real dates.

  If you switch on **Let my online store show an estimated date**, Khayt sends
  that to Khayt Cloud so a storefront can show it in the basket, before someone
  orders. What it sends is when you could start and the hours above — never how
  much work you have. It refreshes on its own, and if it goes quiet your store
  stops showing a date rather than showing a stale one.

### Fixed

- **A MakerRun library with more than 200 saved designs now shows all of them.**
  The library page returns 200 designs at a time, and Khayt was reading the first
  batch as though it were the whole library — so a shop with 250 saved designs
  saw 200 of them and was told nothing about the rest. Khayt now fetches every
  page.

  If it cannot reach the end for any reason it says the list is partial and
  leaves what it had remembered alone, rather than treating designs it never
  received as ones you had deleted.

- **Removing a design from your MakerRun library now removes it from Khayt.**
  Khayt can also see what left since it last looked, so an ordinary sync of a
  changed library is one request rather than two.

### Added

- **A design from your MakerRun library now shows whether you can sell the
  print, and what it was designed to print at.** Each card carries the layer
  height, filament and colour count the designer recorded, and a line saying
  whether the licence permits commercial use.

  Where the licence cannot be read confidently, Khayt says **check the licence**
  rather than guessing — guessing "no" would stop you selling a print you are
  entitled to sell, and guessing "yes" would tell you to sell one you are not.
  The licence's own name is there on hover either way. A "commercial use
  allowed" refers only to the commercial clause; attribution and share-alike
  conditions still apply.

  Print numbers a designer typed in are marked with an asterisk; ones Khayt's
  library measured from the design file itself are not. Hovering says which.

### Changed

- **Syncing your MakerRun library no longer downloads files you already have.**
  Khayt used to fetch every design's file on every sync, because there was no way
  to tell which ones had changed. MakerRun now sends a fingerprint of each file,
  so Khayt downloads only what actually moved and says how many were already up
  to date.

  Checking for changes is cheaper too: Khayt asks "has anything changed since
  last time" first, and only fetches the full list when the answer is yes. A
  design you remove from your library still disappears from Khayt, because that
  question can't report a removal and Khayt doesn't pretend otherwise.

  Downloaded files are also checked against that fingerprint before being saved.
  A file that arrives damaged is reported instead of being written into your
  library under the right name.

### Fixed

- **Status colours are readable in every theme again.** In the Flow design, a
  completed figure on the dashboard and a payment badge were shown in a green
  and a red that did not have enough contrast against the surface behind them,
  and in Blueprint the same was true of the amber used for warnings. They were
  close to the line rather than badly wrong, but below the readability standard
  Khayt holds itself to — and small coloured text is exactly where that matters.
  Each has been nudged the smallest amount that clears it; nothing else about
  the designs has changed.

- **An empty MakerRun library now means your library is empty.** If MakerRun
  answered in a way Khayt could not read — a changed field name, a reply that
  was not proper JSON — Khayt showed no designs at all and said nothing, which
  looks exactly like having saved none. Khayt now says it could not read the
  answer, and says your designs are safe. A library that really is empty still
  simply shows as empty.

  Failures while loading the library also explain themselves rather than showing
  a status number: MakerRun being busy, asking Khayt to slow down, or a session
  that needs signing in again.

- **The customer intake form is now sent with the same protections as every
  other page it links to.** The quote page and the tracking page were served
  with a set of browser security headers; the intake form — the page a shop
  actually shares with its customers, and the only public one that accepts what
  they type — was not, and neither were a few of the small "link expired" and
  "too many requests" pages.

  Those protections are now applied to every response the shop's server sends,
  rather than page by page, so a page added later cannot be left out.


- **A model measured in inches, centimetres or metres is now the right size in the
  preview.** A 3MF file records the units its numbers are in, and the preview was
  reading every file as though it were in millimetres. A part drawn as 12×12×6
  inches showed as 12 mm across instead of 305 mm — small enough to look like it
  fitted the bed when it does not — and a part drawn in microns showed as
  enormous when it fits easily.

  Conversion was never affected: that part of Khayt has always read the units.
  What was wrong was the preview and everything measured from it, so the two
  disagreed about the same file.

- **"Update check failed" now says what actually happened.** When Khayt could not
  check for a new version it showed the technical text the update library
  produced — most often `getaddrinfo ENOTFOUND github.com`, which is what a
  computer with no internet connection produces. That named a hostname and a
  system call and nothing a shop can do about either.

  The common cases now say what they are: no internet connection, GitHub
  temporarily refusing checks from your network, GitHub having trouble, or a
  release that does not yet include an update file for your platform — with a
  note that the last one is a problem with the release rather than with your
  copy. Anything Khayt does not recognise still shows exactly what it said
  before, on purpose: a reassuring message over an unknown fault would hide it.
  The original text is kept either way, on hovering the message, so it can still
  be quoted in a bug report.

### Added

- **Khayt can now send the diagnostics you opted in to.** If you have turned on
  crash or usage reporting in Settings, Khayt has been collecting those reports
  on your own computer and keeping them there — there was nowhere to send them
  to. There is now, and Khayt sends them shortly after it starts and then about
  once an hour.

  Nothing changed about what is collected or how. The reports are stripped of
  anything identifying before they are ever written down, they still never
  include your customers, your orders or your files, and if you have not opted in
  nothing is sent and no request is made at all. Turning an option back off stops
  those reports being sent, including ones already waiting.

  If Khayt cannot reach the internet it simply keeps them and tries later, and it
  waits longer between attempts rather than retrying constantly.

## [3.7.0-beta.10] - 2026-08-27

### Fixed

- **Shipment tracking could go quiet without anyone knowing.** Khayt reads
  delivery updates from SMSA, Aramex and SPL. If a carrier sent its update in a
  slightly different arrangement than expected — a very ordinary difference —
  Khayt could not find the tracking number inside it, and answered the carrier
  as though everything was fine. The shipment then simply never moved past the
  status it was on, and nothing anywhere said why. It looked exactly like a
  carrier that had stopped sending.

  Khayt now reads the common arrangements, and when it genuinely cannot make
  sense of an update it says so to the carrier instead of silently accepting it
  — so the failure shows up in the carrier's own delivery log rather than
  nowhere. Update times sent as `eventTime` are also read now; they were being
  dropped.


- **Hardened a text-escaping helper that could have stopped escaping.** Two
  places in Khayt used a short helper to make customer-supplied text safe to
  display, and each was written to fall back to the raw text if the main
  escaping function was ever unavailable. That never happened — the app always
  loads it, and a build check enforces that — but a helper whose name promises
  it is safe should not depend on another file to keep that promise. Both now
  escape on their own.

- **A Medusa order arrived labelled with an internal id instead of its order
  number.** Khayt asks a Medusa store for the order behind each event, and the
  list of things it asked for was missing two of the ones it then tried to read.
  So when a store had no display number, the fallback that was supposed to catch
  that could never run, and the order landed named after a database id nobody
  recognises. A line item that did not carry its own quantity counted as one for
  the same reason.

  The file Khayt generates for a Medusa store also declares its imports the way
  Medusa's own examples do, which keeps it compiling in projects with stricter
  TypeScript settings than the default.


## [3.7.0-beta.9] - 2026-08-27

### Added

- **Khayt can now cancel and resume a print on a Repetier server.** It could
  watch one and never touch it: every button reported that job control was not
  supported.

  Resume is worth having on its own, even though **pause is still missing**. A
  print stops on its own more often than anyone chooses to stop it — a filament
  runout, or a colour change the machine is waiting on — and this is the button
  that gets it going again. Pause is a different kind of instruction on this
  server than the other two, and Khayt would rather say it cannot do it than
  send a running print something it half-recognises.

### Fixed

- **Every order imported from Salla was recorded as costing nothing.** The price
  column showed 0.00 for all of them, from the day the integration shipped.

  Khayt was reading a field that does not exist in what Salla sends. Nothing
  failed when it came back empty — the number simply became zero, which is a
  price like any other, in the one column a workshop is actually measured in. So
  revenue, margin and every report built on them have been wrong for Salla
  orders, and nothing anywhere said so.

  Khayt now reads the total Salla actually sends. **Existing orders are not
  changed** — Khayt will not rewrite a figure you may have already invoiced
  against — so correct any Salla order still showing 0.00 by hand.

  Two smaller things came with it. Salla orders were all titled "Salla: Order",
  which is no help in a queue of them; they are now named after what was
  ordered. And when a storefront genuinely sends no price, that is no longer
  quietly indistinguishable from a real zero.

- **Orders from Zid are read more carefully.** Khayt expected one payload shape
  and had no way to confirm it — Zid does not publish an example. It now accepts
  either shape, so an order that would previously have arrived unnamed, unpriced
  and impossible to deduplicate now arrives intact.

- **"Detect from printer" found no camera on OctoPrint machines that have one.**
  The button asked OctoPrint where its camera was and read the answer from a
  field OctoPrint has been phasing out — one that is filled in for its own
  built-in camera and left empty for cameras added by anything else. So for some
  setups it worked, for others it silently found nothing, and there was no way to
  tell which you had except by trying.

  Khayt now reads the camera list itself, which every version reports and which
  covers every camera. If a printer has more than one, Khayt asks for the one
  OctoPrint nominates for taking pictures rather than the one it happens to show
  first — those are allowed to be different cameras.

- **A camera that had not taken its first picture yet said it was offline.** A
  printer answering "the camera is there, I just have no picture for you this
  second" was reported the same way as a camera that is unplugged, which sends
  you to check a cable that is fine. It now says **No picture yet**.

- **A Duet 3 with a Raspberry Pi attached could be watched but never stopped.**
  Khayt showed its temperatures, its progress and its job perfectly well, and
  then Pause and Cancel did nothing but report an error — on the one kind of
  Duet where that combination is possible.

  A Duet answers on one of two completely different interfaces depending on how
  it was built, and Khayt learned the second one for *watching* a printer
  without learning it for *controlling* one. The two halves were written a long
  way apart and nobody put them side by side. They now share the same list of
  addresses, so a machine Khayt can see is a machine Khayt can stop.

  The same gap meant **a Duet with a password set refused every command**. Khayt
  signs in for a command the way it already did for a status check.

- **Cancelling a Duet print now does what Duet's own software does.** It sends
  the pause first and the stop second, which is the order the machine's own web
  interface uses — it will not offer you a stop button at all until the print is
  paused. Khayt was sending the stop on its own, into a print that was still
  running. If the stop does not land, the print is left paused rather than in an
  unknown state, and Khayt says so.

## [3.7.0-beta.8] - 2026-08-27

### Added

- **Analytics now shows what each model actually costs you.** Khayt has been
  reading the real filament and time off your printer as each job finishes for a
  while now. Until today it did the arithmetic and showed you an average: how
  close your estimates are, across everything. That tells you how you are doing.
  It does not tell you what to change.

  **Analytics → Cost per model** groups those measurements by the model that was
  printed, so you can see that a particular part is quoted at 41 g and 3.2 h and
  has actually taken 48 g and 3.8 h across four prints — and that you are
  therefore charging about a sixth too little for it every time you quote it. An
  order happened once, at a price already agreed. A model gets quoted again
  tomorrow, which is why this is the useful way round.

  Only prints a **printer measured** are counted, and only jobs that printed one
  thing — a figure divided between several parts is a fair way to split a bill,
  not a measurement of any one of them. Each row says how many prints it is based
  on, because two prints and ten prints do not deserve the same confidence, and a
  model is only flagged as underpriced once there is more than one print behind
  the claim.

  Printing something twice as fast as you quoted is not flagged. You will hear
  about overcharging from your customers.


- **You can install a design someone else made.** Khayt has had the machinery
  for custom designs for a long time and nobody has ever used it, because there
  was nowhere to put one: designs lived inside the application file, which is
  read-only and replaced wholesale every time you update. So adding one meant
  building Khayt from source, and keeping one meant never updating.

  **Settings → Appearance → Your designs → Install a design…** takes a single
  `.khayttheme` file. It appears in the grid with the built-in ones, it survives
  updates, and you can remove it again. Remove the one you are using and Khayt
  hands itself back to Workbench rather than sitting there with no design at all.

  A design is one file, on purpose — readable, easy to send to somebody, and
  possible to look through before you trust it.

  **Khayt checks it before it installs, and again every time it loads.** A design
  is a stylesheet, and a stylesheet in an app that shows your prices and your
  customers' addresses can do more than choose colours: it can quietly call out
  to the internet, put a different number next to a real one, or cover a button.
  Anything doing that is refused, and Khayt tells you which part of the file was
  the problem rather than just saying no. Checking again on load matters because
  a file that was fine when you installed it may not be fine tomorrow — if it
  changes on disk it stops loading, and says so instead of quietly applying.


### Fixed

- **A Repetier printer showed as idle the whole time it was printing.** It
  reported no job, no progress and no filename, whatever the machine was doing —
  and did it quietly, next to temperatures that were correct, which is the
  combination least likely to make anyone doubt the rest of the card.

  Repetier answers two different questions on two different calls: one about the
  machine, one about the job. Khayt only ever asked the first one, and looked for
  the job on it. Nothing was missing and nothing failed; the answer simply was
  not in the reply, and an empty answer reads exactly like an idle printer.

  Progress, the file name, and paused, waiting and offline now all come from the
  call that carries them. A machine with no heated bed also stops reporting a bed
  at 0 °C, which it had been doing for as long as there has been a Repetier
  adapter.

- **"HTTP 409" is not something anyone can act on.** When OctoPrint was running
  but no printer was connected to it — switched off at the wall, unplugged, or
  simply not connected in OctoPrint, which is most of a normal day — Khayt showed
  a red error reading `HTTP 409`, and threw away everything else OctoPrint had
  told it in the same breath.

  That is not a fault. It is a printer that is off, and OctoPrint says so plainly
  in a part of the answer Khayt was discarding. The card now says **Offline**,
  the way every other kind of printer already did.

  The same went for a Klipper machine restarting, which read as `HTTP 503`. Where
  the printer's own server explains itself, Khayt now says what happened and what
  to do about it, and quotes the server's own words beside it — and where it has
  nothing useful to add, it still tells you the status rather than inventing a
  reason.

- **Khayt can now find a printer that changed address, even one that does not
  announce itself.** It could already repair a printer whose address moved — but
  only by listening for printers that broadcast their presence, and the Snapmaker
  U1 broadcasts nothing at all. Which meant the feature could not help the exact
  printer it was written for: it sat on "offline", the same word it uses for a
  printer switched off at the wall, while the real fix was a two-second edit
  nobody knew to make.

  Khayt now goes and asks. If a printer stops answering, it checks the other
  addresses on the same network for something speaking that printer's language,
  and offers to point the machine at it — showing you what it found rather than
  moving anything on its own.

  It also remembers each printer's hardware address while it is working. That is
  the one thing about a printer a router cannot change, so the next time one
  moves, Khayt knows which printer it found rather than guessing from what is
  nearby.

  Why this matters more than a wrong badge: when a printer is at the wrong
  address, every print that finishes is a measurement that no longer exists —
  Khayt reads the real filament and time off the printer at the moment it
  finishes, and those numbers are gone once the next job starts.

## [3.7.0-beta.7] - 2026-08-25

### Added

- **Choosing a design now tells you what it costs.** Khayt's eight designs are
  eight genuinely different screens — that is the point of them — but it meant
  switching could quietly take a number away. Average margin appears on two of
  the eight. Revenue on three. If you picked a design because you liked the look,
  nothing told you what you had given up, and you would only find out by going
  looking for a figure that was no longer there.

  Each design in **Settings → Appearance** now says what it hides or adds
  compared with the one you are using — *"Hides average margin, fleet
  utilisation"* — so you can choose on looks and know the price, or choose on the
  numbers you need. A design that costs you nothing says nothing.


### Fixed

- **The Flow board never marked an order late.** Not "rarely" — never, since the
  board shipped. It asked the same part of Khayt that the dashboard's attention
  bar asks, then misread the answer in two separate ways, and a safety net two
  lines below hid the mistake. So a card that was a week overdue looked exactly
  like one due next month, and the "3 late" warning at the top of the board has
  never once appeared.

  If you use Flow and have wondered why nothing ever looked urgent: it was this,
  and it is fixed.


### Added

- **A Duet 3 with a Raspberry Pi attached can now be added.** It could not be
  before — not "worked poorly", could not be reached at all. That build serves a
  completely different set of web addresses from a Duet that runs its own
  networking, and Khayt only knew the second set, so every request missed and the
  printer looked switched off however healthy it was. Khayt now tries both and
  remembers which one your board answered on.

- **A Duet with a machine password can be polled.** If you have set one, a Duet
  refuses every request from anything that has not logged in — and Khayt had
  nowhere for you to type it, so the printer read as unreachable. Put it in the
  **API key** box on the machine, which now says so: PrusaLink calls that field a
  Password, a Duet calls it the machine password, and Khayt calls it the same
  box. Leave it empty if you never set one; nothing changes for you.

  Neither of these has met a real Duet — there is none here to try. The
  behaviour is covered by tests end to end, but if you have one, this is the
  release to tell us about it.


### Fixed

- **An order that arrives twice from your online store no longer becomes two
  jobs — whichever store it is.** The previous release fixed this for Salla and
  Zid; it was still happening for every store that sends its orders through
  Khayt's cloud link, which is Shopify, WooCommerce, Etsy, Shopware, PrestaShop,
  BASE and Medusa.

  Stores re-send an order when the first attempt is slow or gets no clear answer.
  That is normal, not a fault, and it happened often enough to matter: each
  re-send wrote a second order request, so a job could be printed twice or
  invoiced twice. Khayt now records the store's own order number against the
  request and refuses the second one, and answers the store with *received*
  rather than an error so it stops re-sending instead of eventually reporting
  your import link as broken.

  Orders that carry no order number are still accepted exactly as before — an
  order Khayt cannot recognise is still an order, and losing it would be worse
  than the duplicate.


### Added

- **Medusa stores can send their orders to Khayt.** Pick **Medusa** in
  Settings → Integrations and you get two buttons instead of the usual one: the
  import link, and the code that uses it.

  The second button is the point. Every other storefront here has a settings page
  where you paste a webhook URL; Medusa does not, because it is a framework you
  host yourself rather than a shop you log into. Orders are announced inside your
  own project, to a file you write. So Khayt writes it for you — press **Copy
  subscriber code**, save it as `src/subscribers/khayt-order-placed.ts`, redeploy,
  and every order placed from then on arrives in **Order requests** with the
  customer's name, their email, the line items and quantities, and the order
  number you and they both see (`#1042` — not the internal `order_01J…` id).

  The generated file does two things that are easy to get wrong by hand. It
  *fetches* the order, because Medusa's `order.placed` hands you an ID and
  nothing else — a subscriber that forwards what it was given sends Khayt an
  object with one field in it. And it asks for the line items and addresses
  explicitly, because Medusa omits those unless you name them, which would
  otherwise import an order with no products and no customer.

  If the send fails it writes to your Medusa log and stops there rather than
  throwing, so Medusa does not retry it into a duplicate order.

### Fixed

- **Shopware, PrestaShop and BASE orders imported with less detail than they
  should have.** Their orders were being read by the generic reader rather than
  the one written for them, so a customer name in a field only those platforms
  use was dropped and the order arrived under an internal id instead of its order
  number. Found while adding Medusa, by checking that Khayt's two cloud backends
  agreed about which stores they knew — they did not.

## [3.7.0-beta.6] - 2026-08-25

### Fixed

- **Duet printers showed every job sitting at 0% with no filename.** Not
  occasionally — always, on every Duet, since the adapter was written. Khayt asked
  RepRapFirmware for the values that "change frequently during a job", which is a
  real setting and exactly the right instinct, and the file a job is printing is
  not one of them. So the byte position arrived with nothing to be a percentage
  of. Khayt now asks for the file separately, and a Duet reports its progress and
  the name of what it is printing.

  Its bed and nozzle temperatures could also be swapped or invented. They were
  read from heater slots 0 and 1, which is right on a normal machine and wrong on
  one built differently — a printer with no heated bed was shown its hotend
  temperature labelled "bed". Khayt now asks the printer which heater is which.

- **A Repetier-Server printer always looked idle.** Whatever it was doing:
  mid-print at 42% with a hot nozzle, it read as Idle, 0%, no temperatures. Khayt
  was picking the printer out of the server's reply by position, and the reply is
  organised by name, so it never found the printer at all and quietly showed an
  empty one. It now looks the printer up by name, reads the temperature of the
  extruder actually in use, and no longer prints the word "none" in the queue as
  though it were a filename.

- **A PrusaLink printer never showed what it was printing.** The status endpoint
  Khayt polls does not carry the filename — it never has, on any firmware — so the
  name was blank on every Prusa in the queue. Khayt now fetches it, and shows the
  long name you saved the file under rather than the shortened `SPICE~1.gco` form
  the printer keeps internally.

- **A multi-toolhead Klipper printer showed the wrong nozzle temperature.** Khayt
  always read the first toolhead. On a machine printing with its third — a
  Snapmaker U1, for instance — that meant watching a nozzle sit at room
  temperature all the way through a job. It now reads whichever toolhead is
  actually printing. (What the print *used* was already right: filament totals
  carry across a toolchange correctly.)

- **A Bambu Lab printer that will not connect now says the likely reason.**
  "Timed out — check IP, access code & LAN mode" listed three things that are
  usually all correct. Bambu keeps the connection Khayt uses behind a *second*
  switch, **Developer Mode**, separate from LAN-only Mode; with it off the printer
  accepts the connection and then says nothing at all, which looks identical to a
  dead printer. The message now names it, and the machine dialog says so before
  you spend eight seconds finding out.


- **An OctoPrint printer reported the slicer's guess as the measured weight.**
  When a job finishes, Khayt reads what it *actually* used off the printer. On
  OctoPrint the filament half of that reading was never a reading: OctoPrint fills
  that field from the analysis it runs on the file when you upload it, so it is
  the whole file's predicted total, it is the same number ten minutes in as at the
  end, and it is the same number whether the print succeeded or you cancelled it
  at layer three.

  Shown as a measurement, it did something worse than being wrong: every
  estimate-versus-actual comparison on an OctoPrint job reported the weight as
  *exactly* as quoted, because the quote and the "actual" were the same figure
  arriving twice. A print that used half a spool more than expected looked
  perfect. And those figures are what teach Khayt what your printers really do, so
  the estimator was being taught its own guesses.

  OctoPrint now behaves the way PrusaLink already did: the **time** is measured
  and offered, the **weight** is yours to type, and the dialog says which is
  which. Nothing is silently invented.

### Added

- **Elegoo resin printers (Mars / Saturn) can be added and watched.** Pick
  **Elegoo resin (SDCP)** as the connection type, or press **Scan network** and
  let Khayt find it — which is the easier route, because these printers are
  addressed by a *mainboard ID* that is printed nowhere on the machine, and the
  scan reads it off the printer's own reply.

  The queue shows what a resin job is doing in its own vocabulary — exposing,
  lifting, dropping — with progress counted in **layers**, which is exact, rather
  than extrapolated from elapsed time. Nozzle and bed temperatures read as blank
  rather than as zero, because a resin printer has neither and a `0°` looks like
  a cold hotend. The consumables you actually replace are shown instead: UV LED
  temperature, release-film count and exposure-screen hours.

  **Not yet tested against a real machine.** There is no Elegoo on the bench
  here, so while the protocol and the network handling are covered by tests, the
  final "does this printer answer" step is unproven. If you have a Mars or a
  Saturn, this is the release to tell us about.

### Fixed

- **A Salla or Zid order that arrives twice no longer becomes two orders.** When
  a storefront sends the same order again — and they do, because a delivery that
  times out or gets a slow answer is *retried* — Khayt could write it into your
  queue a second time. The only thing stopping that was a list of recently-seen
  deliveries held in memory, which is emptied every time you close the app, holds
  ten minutes, and holds five hundred. Any of those three running out turned a
  routine retry into a duplicate job: printed twice, or invoiced twice.

  Khayt now records the store's own order number against the order and checks it
  before writing another. That check reads your print log, which is on disk, so
  it survives restarts and busy days. Orders already in your queue are recognised
  too, by the reference shown in their notes.

  A repeat delivery is answered as *received* rather than as an error, so the
  storefront stops retrying instead of eventually reporting your webhook as
  broken when it is working correctly.

- **A measured print no longer disappears when you close Khayt.** When a job
  finishes, Khayt reads what it *actually* used — filament and time — off the
  printer at the one moment those numbers are true, because the printer wipes
  them when the next job starts. Those readings were then kept in memory only.
  So the twenty-four hours Khayt offers a measurement for was really "until you
  next quit": finish a print overnight, close the app in the morning, mark the
  order done, and you were quietly given an *estimate* instead. Correctly
  labelled — but the measurement you had genuinely taken was gone.

  They are now saved, and come back when you reopen. Only the finished jobs are
  kept: a printer never comes back looking like it is still running, so a machine
  that has been off all night cannot greet you with "Printing · 47%".

  This matters more than a tidier number. Measured jobs are what teach Khayt what
  your printers really do — three of them and it stops guessing at print times
  altogether — so every one that evaporated was a lesson the estimator never got.

## [3.7.0-beta.5] - 2026-08-24

### Added

- **A printer that changed address can be found again, instead of just reading
  "offline".** Machines are set up by IP, and an IP is not a promise — a router
  hands out a different one after a power cut or a lease expires, and from then
  on Khayt is asking a device that isn't there. It said *offline*, which is also
  what it says when a printer is switched off, so the one fault with a two-second
  fix looked exactly like the one that needs a trip to the workshop.

  Now, when you **scan the network** in a machine's settings, a printer that is
  *this* machine at a new address is put at the top of the list and labelled
  **"Same printer, new address"**, showing the old address and the new one. One
  click fills the form; nothing is saved until you press Save, as before.

  Khayt also remembers a printer's **serial number** when you add it from a scan.
  That is the one thing about a printer an address change cannot alter, so next
  time it moves it is recognised outright rather than matched by make and model.
  Printers already set up don't have one recorded yet — they pick it up the next
  time a scan finds them where they are supposed to be.

  Khayt will not guess. If two printers on the network could both be the machine,
  it says so and lets you choose, and it will never point a machine at an address
  another machine is already using.

  **Why this is worth more than a tidier error message:** the figures a finished
  print reports — what it actually weighed and how long it actually took — are
  read live and only live. A printer's counters reset when the next job starts,
  so a print that finishes while Khayt is asking the wrong address is not a
  delayed measurement, it is one that no longer exists. That is where the
  "measured" costs and the self-calibrating time estimate come from. This was
  found on a real bench: a Snapmaker U1 had moved from `.77` to `.56`, and the
  shop's completion history was empty rather than merely short.

- **…and Khayt now works that out on its own, instead of waiting to be asked.**
  A scan you have to think to run is no help to the one person who needs it:
  nobody scans a printer they have no reason to believe has moved. So when a
  machine has been unreachable for a couple of polls, Khayt quietly checks the
  network itself, and where it used to print a raw `connect ETIMEDOUT
  192.168.68.77:7125` it now says **"Found at 192.168.68.56 — the address
  changed"**. On the dashboard printer tile, on the kanban machine chip, and on
  **Test connection** in the machine's own settings.

  It is still only telling you. Nothing is changed until you pick the printer in
  **Scan network** and press Save.

  This costs your network almost nothing: the check runs only when a printer is
  actually unreachable and Khayt has not already worked out why, and at most once
  every ten minutes no matter how many machines are down.

- **Khayt now says what is likely to go WRONG with a model, not just what it will
  cost.** Drop an STL, OBJ or unsliced 3MF into the calculator — or pick one with
  **Browse…**, or receive one from a customer through the intake form — and you
  get the things worth looking at before you quote:

  - how much of the surface overhangs past your slicer's support angle, and how
    much of that is near-horizontal underside — the kind that sags rather than
    merely printing rough. They are reported separately because they fail
    differently and are fixed differently.
  - whether the walls are too thin for your nozzle to lay down at all.
  - whether it fits the machine's build volume — and, if it only fits turned a
    quarter-turn, it says that instead of calling it too big.

  It uses the printer you are quoting for, so it answers *your* question: a shop
  whose slicer supports past 55° is told about the faces past 55°, and a 0.8 mm
  nozzle moves the thin-wall line with it.

  Every line carries the measurement behind it — *"24% of the surface overhangs
  past 45°"*, not *"has overhangs"* — so you can disagree with it. A shop that
  supports everything by default can see at a glance which line to ignore.

  It comes **after** the price, never instead of it. And it is honest about what
  it cannot see: this reads the mesh, not a slice, so it knows nothing about
  supports you would add, and it measures the *average* wall — a chunky part with
  one thin fin will not trip it.

  Checked against 110 real models before any of the thresholds were chosen: 56
  raised nothing at all (printer spares, clips, brackets, vases), 32 got a note,
  21 a warning, and exactly one was called unprintable — a mesh whose walls
  average 0.18 mm.

  **On a customer's upload, the triage is for you and not for them.** A visitor
  who prices a model through your intake form sees exactly what they saw before:
  a price. The print-risk report is attached to the request when it reaches your
  **Order requests**, which is the moment it is worth something — you are
  deciding whether to take a job at a price the customer has already been shown,
  and "a fifth of this needs supports" is what turns an acceptable price into an
  unacceptable one. Uploads above 8 MB are still priced but not analysed, so a
  large file cannot make the shop's machine do a large amount of work.

- **Adding a print to a kit it should have been in all along is now a choice
  from a list, not a name you have to retype.** Kits — several printed jobs that
  are one object — were always meant to be filed *after* the work was done. But
  making one asked you to type the name every time, including when the kit
  already existed, which is exactly the wrong way round: you file three parts as
  "Dragon" one week, print the fourth the next, and have to reproduce that string
  from memory. Get it right and it worked. Get it slightly wrong and nothing went
  bang — you quietly ended up with two kits called almost the same thing and the
  totals split between them.

  Select the jobs in the print log and pick the kit from the dropdown beside
  **Add to kit**. Naming one is only asked for when there is a new one to name.
  And if you type something one letter off a kit you already have, Khayt asks
  whether you meant that one — it asks, it never decides, because "Leg L" and
  "Leg R" are one letter apart and genuinely different.

- **A job can be taken back out of a kit without disbanding the whole thing.**
  Choose **Remove from kit** in the same dropdown. Grouping after the fact means
  occasionally grouping the wrong thing, and until now correcting one job meant
  breaking up the kit and rebuilding it — which is why anyone would rather leave
  it wrong. If that empties a kit, its name is tidied away with it; the prints
  themselves are never touched.

### Fixed

- **A camera Khayt guessed at is no longer switched on before anything has
  answered.** Setting up a printer's camera fills in the addresses these printers
  usually use — but "usually" is doing a lot of work there, and for Klipper
  machines there are **two** conventions in the wild, not one. Khayt filled the
  first, ticked **Enabled**, and told you to check the preview. If you didn't, you
  had saved a camera that could never load, and the machine's card showed a tile
  reading *Camera offline* from then on.

  Khayt now tries the addresses before switching anything on. If one answers with
  a picture, the camera is filled in and enabled as before. If none does, the
  usual address is still filled in so you have somewhere to start, but the camera
  is **left off** and it says so — rather than quietly presenting a broken camera
  as a working one.

  Found on a Snapmaker U1 on stock firmware, which reports no camera, has nothing
  listening on the port Khayt was guessing, and answers the other convention with
  an error. Its camera had been switched on and blank the whole time.

## [3.7.0-beta.4] - 2026-08-23

### Added

- **The storage provider list now links you to each provider's signup page.**
  Picking a provider in **Settings → Print library location** used to leave you
  with a form asking for an account ID or a region — things you can only read off
  a dashboard you have to have an account to see. So the one shop the list helped
  least was the shop that had never used cloud storage before. Each provider now
  shows a link straight to where you open an account with them, next to what it
  costs and whether downloads are billed. **Other (S3-compatible)** shows no
  link, since there is nothing to sign up for.

  The same links are in [docs/CLOUD-STORAGE.md](docs/CLOUD-STORAGE.md) if you
  would rather read the comparison first.

  These are plain links — **Khayt earns nothing from them.** Should that ever
  change, any link that pays Khayt will say so on the spot, before you click it,
  and the plain link will stay in the docs.

## [3.7.0-beta.3] - 2026-08-23

### Added

- **A macOS build, which `beta.2` did not have.** `beta.2` went out for Windows
  and Linux only, so a Mac on the beta channel stayed on `beta.1` and never saw
  the print library that can outgrow its disk. This release carries **no app
  changes at all** — it is `beta.2`'s code, built and notarized for Apple
  Silicon so it will install on a Mac.

  On Windows or Linux there is nothing here for you: `beta.2` and `beta.3` are
  the same app, and you can stay where you are.

## [3.7.0-beta.2] - 2026-08-23

### Added

- **Your print library can now be bigger than the disk it lives on.** Khayt can
  move models you have not touched in a while into cloud storage and take them
  off this computer, then download them again automatically the first time you
  open one. The library looks exactly the same — every model still listed, still
  at its real size, with a mark showing it is in the cloud. Thumbnails always
  stay on your computer, so browsing keeps working with no internet at all.

  This is different from the object-storage backup Khayt already had, and it is
  worth being clear about why. **The backup never freed any space** — it is a
  second copy, so a 50 GB library became 50 GB here and 50 GB there. This moves
  the file rather than copying it. You can run both: the backup for "the
  workshop burned down", this for "the laptop is full".

  Switch it on in **Settings → Print library location → Move old models to the
  cloud**, choose how many days to keep files locally (90 by default), and press
  **Free up space now**. It tells you how many models and how much space before
  it does anything.

  **Nothing is deleted until the cloud has provably received it.** Each file is
  uploaded, then checked in a separate request against a checksum of the file on
  your disk — not just its size, which a half-finished upload can match. Only
  then is the local copy removed. Anything that cannot be verified is left
  exactly where it is and named in the result, so you can see which model and
  why. **Bring everything back** downloads the whole library again if you change
  your mind or are moving away from Khayt.

- **Pick your storage provider from a list instead of typing an endpoint.**
  Settings now has a provider dropdown covering Cloudflare R2, Backblaze B2,
  IDrive e2, Wasabi, Storj, Hetzner, Scaleway, OVHcloud, DigitalOcean Spaces,
  Akamai/Linode, Amazon S3, Google Cloud Storage, Oracle Cloud, Synology C2, and
  MinIO or a NAS you run yourself. Choose one, type the single thing only you
  know — an account ID, a region — and Khayt builds the endpoint. Each option
  shows roughly what it costs and whether downloads are billed, which is the
  part that actually matters for a print library, since reprinting an old order
  pulls the model back down.

  These all worked before; they just needed an endpoint URL that nobody can type
  from memory. Anything not on the list still works under **Other**.

- **Google Drive can now hold your print library.** If you already pay Google for
  storage, connect the account in Settings and Khayt will use it exactly as it
  uses a bucket, including for freeing up disk space. **Khayt can only see files
  it put there itself** — it has no access to the rest of your Drive, by design.
  Signing in happens in your real browser, never inside Khayt.

  You will need a free OAuth client ID from a Google Cloud project; the steps are
  in [docs/CLOUD-STORAGE.md](docs/CLOUD-STORAGE.md). Dropbox and OneDrive do not
  need any of this — point the library folder at their synced folder and it
  already works.

### Changed

- **The design library Khayt syncs with is now MakerRun, at `makerrun.com`.**
  BedReady split into two products: the library — your saved designs, and the
  account you sign in to — moved to **makerrun.com**, and `bedready.io` kept the
  file converter. Khayt now connects, signs in and pulls your designs from
  makerrun.com.

  **There is nothing for you to do, and you do not have to sign in again.** It is
  the same account with the same saved designs; only the address changed. If you
  had already connected your account, it stays connected. The Connect button now
  opens `makerrun.com/app-link` instead of the old address.

  The panel is now called **MakerRun library** and the button reads **Connect
  MakerRun account**, in all nine languages.

  **"Download to folder" keeps using the folder you already have.** New downloads
  go to `Downloads/MakerRun-Library`, but if you had already downloaded designs to
  `Downloads/BedReady-Library`, Khayt keeps saving there instead of scattering one
  library across two folders. Nothing on disk is moved or renamed, and the message
  after a download names the folder it actually wrote to.

  Bed Ready's own site links — the Feedback button and the Help menu — still go to
  `bedready.io`, which is the converter and is unchanged.

- **AI assist now uses a newer Claude model by default.** New shops get
  `claude-opus-5` instead of `claude-opus-4-8`. **If you already have a model
  set in Settings → Automation → AI assist, yours is left exactly as it is** —
  change it there if you want the newer one.

  The newer model reasons before it answers, so an AI answer may take a few
  seconds longer and cost a little more per call on your own API key. Khayt's
  own cost figures know the new price, so what the AI usage panel shows you
  stays accurate. The model box is still free text: type any model name your
  key can reach.

## [3.7.0-beta.1] - 2026-08-21

### Changed

- **Cloud sync now sends only what changed.** Every save used to upload your
  whole shop — every order, every client, every spool — because one card moved.
  That cost grows with your history rather than with your work, so the longer
  you have used Khayt the more each save cost. Khayt now sends just the records
  that changed, and the whole shop only occasionally, to keep the cloud copy
  tidy.

  The previous releases taught Khayt to *read* that format; this one starts
  *writing* it. Nothing about your data or its encryption changes, and there is
  nothing to switch on.

  **You do not have to update every machine first.** Khayt and the server work
  out together whether every computer signed in to your shop can read the new
  format — including one that is switched off, and the head office view if you
  run branches. If any of them cannot, your shop quietly keeps sending whole
  stores exactly as before, with no error and nothing for you to do. The saving
  starts on its own once they are all updated.


## [3.6.0] - 2026-08-21

The 3.6.0 beta line, released as stable. Individual beta and candidate entries
are kept below; this is what changed for you since 3.5.3.

**Khayt now learns what your prints actually cost.** Until this release every
figure the app gave you came from a formula — a guess about your printer, your
filament and your infill, applied to a shape. Now a model dropped on the
calculator becomes a quote, the printer reports the real filament and duration
when the job finishes, the settings that worked are remembered against the file,
and the estimator corrects itself from the jobs you have actually completed. An
estimate also says whether the rate behind it was measured or assumed, and on
which print it was measured — a number you cannot question is worse than one you
can.

That is why this line spent three weeks in beta: it changes **what your customers
are quoted**, and how every geometry-based time estimate is worked out. The early
betas got it wrong in both directions — a 100 mm part quoted at roughly double, a
five-hour print shown as 1% done with 178 hours remaining — and both were found by
running real jobs on a real printer, not by running the tests.

**Khayt also works outside the Gulf now.** Tax can be added to a price rather than
included in it, so a US shop quoting 100 invoices 108.25 where it used to invoice
100. Thirty country presets come with it, your documents print in the language
your shop chose rather than that language and Arabic, and a new shop outside Saudi
Arabia is no longer set up for Saudi e-invoicing.

**And four security holes are closed**, one of which exposed customers' messages
to anyone holding a portal link.

### Fixed — security

- **Anyone with a portal link could read the whole message thread on it.** A
  customer portal link now proves who is holding it before it will show a
  conversation, and Khayt no longer has any way to read a thread without that.
- **A printer address written as a number could point Khayt at your own network.**
  An address like `2130706433` is another way of writing `127.0.0.1`, and the
  check that was meant to refuse it did not recognise the form.
- **The converter could be made to write a file anywhere the app could read.**
- **The brute-force lockout never actually locked.** Ten wrong LAN PINs were
  meant to lock the door; they did not.
- **Every known vulnerability in the parts Khayt ships is patched**, including the
  move to Electron 42.8.1.

### Fixed — your data

- **Restoring a backup without closing Khayt could push the restored data over
  newer data on your other devices.** With cloud sync on, restoring a backup or a
  named restore point while the app was running could send that older copy up as
  the latest, and every other device would take it. Nothing warned you.
- **Your data is now copied aside before any update touches it**, so there is
  always a copy from immediately before the version changed.
- **When cloud sync fails, it now says why.** The status used to read "Sync
  error" and nothing more, indefinitely.
- **Khayt Cloud no longer re-downloads your whole shop every time you open the
  app.** It asks for the part it is missing and folds that onto the copy it
  already has.
- **Cloud sync uploads about a sixth as much.** If you run a second machine on
  3.6.0-beta.16 or earlier, update it — otherwise it stops syncing until you do.

### Added — what a print costs

- **Drop a model on the calculator and get a quote.** One drop zone takes STL,
  3MF and g-code, and your customers can price their own model too — optional,
  and off until you turn it on.
- **Khayt learns what a print actually cost.** When a job finishes on a Moonraker
  or Klipper machine, the real filament and duration are captured and kept
  against the file.
- **Estimates that correct themselves.** Once a few jobs have finished with
  measured figures, the estimator calibrates against them rather than against a
  fixed assumption.
- **Settings that worked, remembered.** A print file keeps the setups you have
  used, and a model you have printed before is priced from its own prints.
- **Khayt says when a model is one it cannot price**, instead of guessing.
- **3MF files now give up their slicer figures**, and **Bambu and Orca print times
  are no longer silently dropped** — neither had ever worked.

### Added — your print library

- **Keep the library on a network drive, an external disk, or a synced folder**,
  and back it up to object storage alongside the backup folder.
- **Khayt recognises a file you already have** — including a g-code file your shop
  re-sliced, which used to come back as a stranger — and there is now an
  **Identify** button for files it cannot place.
- **Drop a .zip straight into your print files.** Model packs arrive as archives.
- **Documents that travel with a product** — assembly instructions, a datasheet, a
  licence.

### Added — buying, stock and kits

- **Consumables reach the reorder list and purchase orders**, which until now only
  filament could, and they can be given categories.
- **Receiving a filament purchase order records what it cost.**
- **A fee can be a percentage**, not only a fixed amount, and **marketplace fees go
  onto a quote in one click** for Etsy and the like.
- **Kits — several prints that are one object.** A figure printed as a head, a
  body and a base is one thing to the customer. Kits can be renamed, and they
  reach Bed Ready.

### Fixed — the converter and colour

- **A large 3MF could convert into a model missing most of itself**, and report
  success.
- **The converter stopped the app while it worked.** That work has moved off the
  main process.
- **A big multi-colour 3MF could open as if it had no colours at all**, and **the
  top colour was dropping out of the print.**
- **Prints took about twice as long as they needed to** — the base of a relief was
  being printed at full detail.
- **HueForge FLAT mode** — colour by region instead of by height.

### Added — elsewhere

- **"Across the branches" now shows the money, and what is late.** The
  organisation overview counted work and said nothing about what it earned. Each
  branch is shown in its own currency and the figures are the branch's own.
- **Elegoo resin printers** — Mars and Saturn machines.
- **The production queue opens on the board**, and there is now a **Help menu**.
- **Low stock can have its own colour**, under Settings → Appearance.
- **Bed Ready no longer calls itself a beta.**

## [3.6.0-rc.4] - 2026-08-14

### Added

- **"Across the branches" now shows the money, and what is late.** Until now the
  organisation overview counted work — in flight, printing, on hold — and said
  nothing about what any of it earned. Each branch now also shows what it earned
  and what it is still owed, plus how many of its jobs are late or due today, and
  the chain totals sit at the top.

  The figures are the branch's own. They are produced by the same code that
  branch's dashboard and analytics use, so a credit note, a refund and a voided
  invoice all subtract exactly as they do on the branch's own screen — a chain
  total you cannot reconcile against the branch it came from is worse than no
  total at all.

  **Each branch is shown in its own currency.** If your branches price in
  different currencies, Khayt shows each one honestly and does not add them up:
  a single total would mean applying one branch's exchange rates to another
  branch's books. Where a branch could not be read, the totals say so rather
  than quietly leaving it out.

  Late and due-today are counted against *your* calendar day, so a branch in
  another timezone is judged by the day you are actually having.

### Fixed

- **Restoring a backup without closing Khayt could push the restored data over
  newer data on your other devices.** If cloud sync was on and you restored a
  backup, a named restore point, or imported a backup file while the app was
  running, the next sync could send that older copy up as if it were the latest
  — and every other device would take it. Nothing warned you, and the newer
  records were gone.

  Khayt now treats a restore the way it treats a fresh start: it forgets what it
  thought the server had, fetches everything again, and merges, so the newer
  version of a record always wins. Restoring after closing and reopening the app
  was already safe and is unchanged.

### Changed

- **Khayt Cloud no longer re-downloads your whole shop every time you open the
  app.** Once Khayt has read your data from the cloud, it remembers what the
  server had and asks only for what changed since — including on the first sync
  after a restart, which until now always fetched everything.

  For a shop on a cloud server that supports it, the sync at startup drops from
  the size of your whole shop to the size of the changes, and nothing about your
  data or your setup changes. The remembered copy is kept encrypted on this
  computer with your own sync passphrase, exactly like the copy on the server.

  Khayt goes back to fetching everything whenever it cannot be sure the shortcut
  is safe — after you restore a backup, after a passphrase change, or on a new
  machine — because a full fetch is the version that can never lose an edit.

## [3.6.0-rc.3] - 2026-08-14

### Fixed

- **When cloud sync fails, it now says why.** The status in cloud settings turned
  red and read "Sync error", and that was everything you got — no cause, no next
  step, and it stayed that way. The most likely reason is one you can act on: a
  shop whose store has outgrown its plan's size limit. The server has always
  explained that in plain words; Khayt was throwing the explanation away and
  showing a status code to nobody.

  Hover the sync status to read the reason. Sync failures that carry no
  explanation still show the code, which is what a bug report needs.

### Added

- **The customer portal's free-tier trial now exists — and does nothing yet.**
  The plan card promises free shops a 30-day portal trial; this is the machinery
  behind that promise.

  **Nothing changes for anyone today.** Khayt Cloud is in beta, every plan is
  free, and the trial clock does not run: publishing portal links is unaffected
  and no countdown appears. Time spent on the portal during beta is **not**
  counted against the trial either, so a shop that has been publishing links all
  through the beta still gets its full 30 days if and when billing starts.

  Once billing does start, a free shop's clock begins at its **first published
  portal link** — not at signup — because that is the moment the trial is
  actually about. The remaining days show in the cloud settings card, and
  subscribing restores publishing immediately.

### Added

- **Khayt Cloud can now read a store that arrives as a base plus a chain of
  changes**, which is the first half of sending only what changed instead of
  your whole shop on every save. Nothing sends changes that way yet and no
  server offers them, so there is no visible difference today — this is the
  half that has to be in the field first, so that no machine can meet the new
  format without understanding it.

  If a server ever does return that format to a copy of Khayt that cannot
  assemble it, sync stops with an error rather than quietly handing over a store
  that is missing its newest edits.

### Added

- **Khayt Cloud now shows what it will cost — and that it costs nothing yet.**
  The cloud settings card carries a three-tier price ladder: Free, Cloud and
  Branches. While Khayt Cloud is in beta every plan is free, so each paid price
  is shown **struck through** next to "Free during beta".

  The prices are real and are what the tiers will cost. They are shown now
  precisely because they are not being charged: a shop should be able to build
  on Khayt Cloud knowing what it will cost later, rather than discover a price
  after committing to it. Nothing can take payment today, and no existing
  feature moved behind a paywall — the desktop app remains free forever and
  works with no account at all.

  Prices follow the shop's own currency (SAR and USD are listed; everywhere else
  shows USD rather than a conversion that would silently go stale). The Branches
  tier is labelled "Not built yet", because multi-branch support is not finished
  and a price without that label would read as something you could buy.

### Added

- **Updating the Microsoft Store listing is now a repeatable ten-minute job
  instead of an undocumented one nobody was doing.** The MSIX had been built on
  every release and submitted on none of it — `electron-builder --win appx` ran,
  the package went to a 30-day workflow artifact, and that was the end of the
  pipeline. Store users sat on whatever build was last uploaded by hand, with no
  way to update: MSIX updates come from the Store, and the Store had nothing
  newer. This surfaced as a user saying their Store copy was very old and they
  had never updated it. Nothing was wrong on their machine.

  The listing copy now lives in `store/microsoft/listing.json` and ships through
  pull requests like everything else, so a description change is reviewable and
  the Store stops being a place where text is edited by hand and forgotten.
  "What's new" is generated from this file's entry for the version being
  released. Every Store limit — description, features, search terms, captions — is
  checked on every PR, so a listing that would be rejected fails in review instead
  of in a certification queue on release day.

  Store screenshots are captured from the real app on demo data at 1920x1080 and
  checked against Microsoft's requirements (`npm run capture:store-screenshots`).

  A `submit-store` job is wired into the release workflow for stable tags, which
  would submit the package and the listing as one submission — but it is inert,
  and will stay that way for the foreseeable future.

  **It cannot be switched on, and that is an account limit rather than an
  unfinished piece.** Khayt's Store account is an individual
  developer account; individual accounts cannot associate a Microsoft Entra
  tenant, and without a tenant there is no way to obtain the credentials any Store
  API needs. So the upload itself is still done by hand — and the tooling above is
  aimed squarely at making that quick: `npm run store:manual` writes a paste sheet
  with every listing field pre-validated and counted, the screenshots are already
  at Store spec, and the MSIX artifact is now kept for 90 days instead of 30, so a
  stable release stops losing its package after a month. The release job stays in
  place and inert, ready for the day the account becomes a company account.
  [docs/MICROSOFT-STORE.md](./docs/MICROSOFT-STORE.md) has the detail.

## [3.6.0-rc.2] - 2026-08-13

### Fixed

- **Every "Copy link" button in the app was copying nothing.** Reported from the
  field against the Shopify import link: with cloud sync connected the
  storefront links in **Settings → Storefronts & Payments** render as live
  buttons, clicking one answers "✓ Import link copied", and pasting anywhere
  produces nothing at all. It was never a Shopify problem, and nothing was
  missing at the user's end — the same failure hit all ~25 copy buttons in the
  app: portal and quote-approval URLs, the LAN QR link, the calendar
  subscription link, the intake link, the reorder list, colour hex codes, print
  plans, the ZATCA CSR, the tracking URL.

  The app grants the interface only the browser permissions it needs, and that
  list named the camera (for the filament label scanner) but not
  `clipboard-sanitized-write` — the permission the browser engine checks on
  every clipboard write. So every write was refused. Each button then discarded
  the refusal and printed its success message regardless, which is why an
  app-wide outage looked like it was working and went unreported for so long.

  Copying now goes through the main process, which needs no such permission and
  works from places the browser API refuses outright (a menu handler, or after
  an `await`). The permission is granted as well, so the direct path works too.
  *Reading* the clipboard stays denied — Khayt never pastes on your behalf, and
  that is the half that could see what else you have copied. Every copy button
  now reports honestly: if a copy ever does fail, it says so, and where it is
  useful it shows the link so it can still be selected by hand.

### Security

- The slicer executable a shop configures is now checked against a positive
  allowlist of known slicer names rather than a denylist of shell names. A
  restored or synced settings snapshot could otherwise point "your slicer" at a
  stock system tool (`find`, `awk`, `xargs`, …) that runs an arbitrary command
  from its arguments, turning a click on **Slice** into code execution. Every
  real slicer keeps working; nothing else launches.
- Bumped the bundled `js-yaml` (via `electron-updater`, which parses the update
  feed) from 4.3.0 to 4.3.1, closing a quadratic-CPU denial-of-service parsing
  advisory (GHSA-5p4m-2wfm-xmqj). Production dependency audit is clean again.

## [3.6.0-rc.1] - 2026-08-12

The candidate for **v3.6.0 stable**. There is no behaviour change over
`beta.19` — it is the same code under a name that says what it is for.

The 3.6 line changes **what your customers are quoted**, and how every
geometry-based time estimate is worked out. That is why it has been a beta since
2026-07-31 rather than going straight to stable, and it is why there is a
release candidate at all: this installs from the same pre-release channel as the
betas and reaches nobody on stable, so the exact code proposed as v3.6.0 can be
put in front of real orders and real printer jobs before it becomes the default
for everyone.

**If you price unsliced models, re-check a quote you have not yet sent.** The
numbers moved in `beta.9` and `beta.10`, for two different reasons — see
[docs/BETA-RELEASE.md](./docs/BETA-RELEASE.md). Figures that came from a slicer
are unaffected; those were never estimates.

## [3.6.0-beta.19] - 2026-08-12

### Fixed

- **Low stock is readable again on a light theme.** The previous release gave
  "low stock" its own colour so that recolouring it would not also recolour
  overdue jobs and ageing spools. That part was right, but the new colour was a
  fixed amber that ignored your theme — and every theme deliberately darkens its
  amber for the light appearance so it stays legible on a pale background. The
  result was pale amber text on white: still there, much harder to read, on all
  seven themes.

  Low stock now follows your theme's own colour again, in both light and dark,
  and the swatch under **Settings → Appearance** shows the colour actually in
  use rather than a fixed one. Nothing changes if you had already chosen a
  colour of your own — that still wins, still applies to low stock alone, and
  now survives switching theme. Choosing a colour still leaves overdue jobs and
  spool age on the theme's warning colour, which was the point of the original
  change.

## [3.6.0-beta.18] - 2026-08-12

### Changed

- **Cloud sync now uploads about a sixth as much.** Every save sends your whole
  shop to the cloud, and until now it went uncompressed — on a real shop, 59 KB
  where 9 KB will do. The previous release taught Khayt to *read* the smaller
  format; this one starts *writing* it. Nothing about your data or its encryption
  changes, and there is nothing to switch on.

  **If you run Khayt on more than one computer, update them all.** A machine
  still on **v3.6.0-beta.16 or earlier** cannot read the new format and will
  report "Update check failed"–style sync errors until it is updated. It cannot
  lose anything — a copy that cannot read the cloud is also unable to overwrite
  it — but it will stop syncing until you update it. One machine on its own is
  unaffected either way.

### Added

- **Documents that travel with a product.** Attach assembly instructions, a
  safety sheet or a drawing to anything in your catalog, and it comes along with
  every order for that product — no re-attaching it each time. They are listed on
  the **work order** so whoever makes it can see them, and on the **delivery
  note** so whoever packs it knows what goes in the box.

  Each document has a tick for whether it ships. A machine setup sheet is for
  your floor and stays off the customer's paperwork; an assembly guide is for the
  customer and appears on both. Documents attached before this existed are
  treated as shipping, since that is what attaching one used to mean. Removing a
  document only deletes the file once you save — cancel the dialog and it is
  exactly where it was.

- **Marketplace fees go onto a quote in one click.** If you sell through Etsy,
  Shopify, eBay, Amazon and the rest, their cut is part of what a job really
  costs you — and until now you had to remember each platform's numbers and type
  them onto every quote. Pick the marketplace above the extra charges and its
  fees are added for you: Etsy's two percentage fees **and** its 0.20 listing
  fee, all as ordinary quote lines you can still edit or delete.

  The rates shipped are a starting point, not gospel — platforms change them, and
  they differ by country, category and plan. Edit them and your figures are kept;
  they are never quietly replaced by ours on an update. Switching marketplace
  swaps the fees rather than stacking a second set on top, and your own charges
  are left alone throughout.

- **Low stock can have its own colour.** Under Settings → Appearance, beside the
  accent colour. It highlights filament and consumables that are running out, and
  it is deliberately separate from the general warning colour — that one also
  marks overdue jobs and ageing spools, so recolouring "low stock" no longer
  recolours all of them too. The picker updates as you drag it, and **Reset**
  puts it back to the theme's own colour.

## [3.6.0-beta.17] - 2026-08-12

### Fixed

- **Security: a printer address written as a number could point Khayt at your own
  computer.** Khayt only polls printers on your local network, and refuses an
  address like `127.0.0.1` that would make it talk to the machine it is running
  on. But `127.0.0.1` can also be written `2130706433`, `0x7f000001` or `127.1` —
  the same address in different notation, which connects to exactly the same
  place — and those three were let through. Every spelling is now recognised for
  the address it is. Outbound webhooks were never affected: they pass a second
  check that looks the address up properly, and that one always caught it.
  Ordinary printers and mail servers on your network are unaffected.

- **Sales tax now reaches the rest of the app, not just the invoice.** Tax that
  is added to your prices rather than included in them arrived on the invoice
  first, and nine other places still worked the old way — analytics and profit,
  the loyalty points a customer earns, the monthly tax-collected figure, the
  accounting export and the journal rows, and the work order sheet. All of them
  quietly assumed your prices already contained the tax, so a shop adding tax at
  checkout saw revenue understated by the tax on every screen, and exported a
  bookkeeping file whose invoice totals were short by the same amount — silently,
  because the file itself was perfectly well-formed.

  Everything now asks the same place how your shop prices, so the invoice you
  send, the revenue you report and the file your accountant receives agree.
  Shops with tax included in their prices are unaffected to the cent.

### Changed

- **Khayt can now read a compressed cloud backup, ahead of writing one.** Cloud
  sync uploads your whole shop each time it saves, and it has always uploaded it
  uncompressed — on a real shop that is about 59 KB going out where 9 KB would
  do, every time anything changes. This release teaches Khayt to *read* the
  smaller format; a later one starts *writing* it. Doing both at once would break
  sync for anyone running two computers until they had updated both, so the
  reading has to be everywhere first. Nothing about your data or its encryption
  changes, and there is nothing to switch on.

### Added

- **Tax now works outside the Gulf.** Khayt had one tax, at one rate, priced one
  way: VAT, 15%, already inside the price you typed. That is right for Saudi
  Arabia and most of Europe and wrong for the two largest English-speaking
  markets — in the US and Canada a price is quoted **without** tax and the tax is
  added at the end. That is not a display difference; it changes what the
  customer is asked to pay, and a shop in Ohio quoting $100 was invoicing $100
  when it should have been invoicing $108.25.

  A new **Tax rules for** setting under Invoice Defaults carries presets for
  thirty countries — the name the tax goes by (VAT, GST, Sales Tax, TVA, KDV,
  消費税), the usual rate, whether local prices include it, and what the shop's
  tax number is called, because printing "VAT No." above an Australian ABN is
  wrong in a way an accountant notices immediately. Beside it, **Your prices**
  chooses include-tax or add-tax-at-checkout, and shows you the arithmetic on a
  price of 100 rather than describing it.

  **More than one tax is now possible**, which matters where two are charged
  together and remitted separately — Canada's GST and PST, India's CGST and SGST
  — including rates charged on top of other rates.

  **Nothing changes for an existing shop.** A shop with VAT switched on at 15%
  computes the identical figure it always has, to the cent; the old settings are
  still there and still work. Countries are a starting point you can edit, and an
  unlisted one charges nothing until you say otherwise rather than guessing at a
  rate you might not notice.

### Added

- **Your data is now copied aside before any update touches it.** Khayt already
  protected the store against crashes — writes are atomic, there is a
  one-generation rollback, a half-written file is repaired on the next launch,
  and a store written by a *newer* Khayt is refused rather than overwritten. None
  of that covers the case where nothing goes wrong except the update itself: a
  version whose own data migration is faulty reads your shop, converts it, and
  saves the result, with nothing to notice. The rollback covers exactly one save,
  and the daily backup is filed under today's date — so the first backup after
  the update overwrites the last good one from the same day. You would find the
  damage on Tuesday and the newest clean copy would be Monday's, missing
  everything Monday added.

  The first time a new version opens a shop saved by an older one, it now keeps a
  complete copy first, exactly as it was on disk, before anything reads or
  rewrites it. One file per update you pass through — a handful over the life of
  an install — and they are **never** deleted by the routine 30-day cleanup, which
  had been the other way this insurance could quietly disappear on the thirtieth
  day. They sit alongside your daily backups and restore the same way.
### Fixed

- **Quotes and invoices now print in the language you chose, not that language
  and Arabic.** Every customer-facing document — quote, invoice, credit note,
  delivery note — printed each label twice: your working language, then Arabic
  underneath. Not "your other language": the second half was always Arabic, in all
  nine translations, so a French shop sent customers French and Arabic and an
  English shop sent a quote headed **عرض سعر**. The same went for the business
  name and address block, and an English quote also carried a **Hijri date** row
  beside the Gregorian one.

  A new **Document language** setting under Invoice Defaults decides. It is set
  to **Automatic**, which prints one language for everyone except shops working
  in Arabic — there the English pairing is doing real work for overseas customers,
  so it stays exactly as it was. **Bilingual** and **My language only** are there
  to override it either way.

- **And when a document is bilingual, you now choose which language goes second.**
  Arabic was not "the other language", it was the only one there had ever been —
  the labels were hardcoded English/Arabic pairs, so no other combination could
  be expressed. A **Second language** picker offers all nine, so a shop can
  invoice in English and French, or German and Spanish. Every printed label moved
  into the translation files to make that possible, which fixed something else on
  the way: the labels themselves were English-or-Arabic, so a German shop's
  invoice said "Description" and "Qty" no matter what language it was working in.
  It now says **Beschreibung** and **Menge**.

  The shop's own name, address, tagline, terms and footer are stored as an
  English/Arabic pair rather than as nine, so those print alongside the labels
  only when the second language is the one they are actually written in. A quote
  in English and French shows French headings without pairing them with an Arabic
  address.

- **The credit note, delivery note and work order now follow your language too.**
  All three were written as English-or-Arabic throughout — not bilingual, just
  two hardcoded options — so a shop working in any of the other seven languages
  got an English document and no setting changed it. A German shop's delivery
  note said "Deliver to", "Courier" and "Tracking"; it now says **Liefern an**,
  **Versanddienst** and **Sendungsnummer**, and the work order its shop floor
  reads says **Arbeitsauftrag**, **Gewicht (g)** and **Zeit (Std.)**. All three
  honour the bilingual setting and the second-language choice as well.

  **ZATCA outranks both settings.** Saudi Phase 1 requires Arabic specifically —
  not merely a second language — so while ZATCA e-invoicing is switched on,
  documents stay bilingual *and* the second language stays Arabic, whatever is
  picked. The picker hides itself and says why rather than appearing to work.
  Nothing you have already sent changes, and no shop can drop into
  non-compliance through a dropdown. A shop working in Arabic already satisfies
  the requirement with its main language, so its own choice is left alone.

- **A new shop outside Saudi Arabia is no longer set up for Saudi e-invoicing.**
  The "ZATCA e-invoicing fields on invoices" box in first-run setup was ticked for
  everyone, whatever language was chosen — so shops with no connection to the
  authority were quietly issuing invoices stamped "ZATCA Phase 1 compliant
  invoice" with a TLV QR code, to customers who had never heard of it. It now
  starts ticked only for an Arabic setup, and stays visible either way, because a
  Gulf shop may well work in English. Existing shops are untouched; the setting is
  where it always was, under Invoice Defaults.

## [3.6.0-beta.16] - 2026-08-10

### Fixed

- **A consumable purchase order is no longer accused of being priced 1000× too
  high.** The banner that finds filament orders priced per spool where a per-gram
  rate belongs judged every purchase order by the same rule — anything above a few
  units of currency per unit must be a whole-spool figure in the wrong field. That
  reasoning only holds for filament, which is ordered in grams. A consumable is
  ordered in the shop's own unit, so five boxes of mailer bags at 12 each tripped
  it, and so would any consumable costing more than about 5 per box, sheet or
  piece. The warning sat permanently above the purchase orders, told the owner
  their amounts were wrong when they were right, and offered no way to dismiss it —
  and the correction it proposed would have divided the price by a spool weight,
  writing the very 1000× error it claimed to have found. Consumable orders are now
  left out of that check, which is filament-only by construction. Orders with no
  kind recorded — every order predating consumables, and the ones actually holding
  the defect — still count as filament and are still caught.

- **Setting up a checkout no longer bumps the Electron version.** (Developer
  tooling; no effect on the app.) The first `npm run test:e2e` in a fresh clone or
  worktree installed Electron with an unpinned `npm install electron --save-dev`,
  which resolved to the newest release and wrote it back — so `package.json` and
  the lockfile came out modified by a command that was only meant to run the
  tests, and the suite then ran against a different Electron than `npm ci` gives
  CI. It now installs the version the lockfile already pins, and leaves both files
  alone.

- **Receiving a filament purchase order now records what it cost.** An order
  drafted for you — at the reorder point, or from **Draft purchase orders** in the
  reorder list — was restocked onto the shelf when it arrived and then booked no
  expense at all. Nothing failed and nothing warned: the spool was simply paid for
  and missing from your material spend, which understates the filament cost that
  analytics reports and that your pricing is worked out from. The same order now
  books its own cost, split across part shipments if it arrives in more than one.

  Three smaller things came from the same cause and are fixed with it: the receive
  box offered a flat 1000 g instead of what was outstanding, and a filament order
  could never finish — it stayed **Partial** however much of it arrived; the
  progress bar beside a partly received order never appeared; and the purchase
  orders in **Export all data (CSV)** carried a blank date and a blank total.

- **Drafted purchase orders no longer show `po.status.draft` where the status
  should be.** Every order created by the "Draft purchase orders" button, or
  automatically at the reorder point, is a draft — but "draft" was the one
  status with no translation, in any of the nine languages. The badge printed the
  raw key instead, and rendered as an unfilled pill because it had no colour of
  its own either. It now reads "Draft" in a muted grey, in every language.

- **The purchase order status filter now lists drafts, and no longer offers a
  status that does not exist.** The dropdown above the purchase orders had an
  entry for "Pending" — nothing has ever marked an order pending, so choosing it
  could only ever empty the table — while **Draft**, far and away the most common
  status once orders are drafted for you, was missing from it altogether. There
  was no way to narrow the list down to the orders still waiting to be placed.
  Pending is gone and Draft takes its place, at the front where the lifecycle
  starts.

- **The "receive purchase order" dialog no longer asks for a weight in two units.**
  Receiving a consumable order captioned the amount box `Weight received (g) (pcs)`
  — the translated label already ends in "(g)" in eight of the nine languages, so a
  second unit was appended to it, and a count of boxes was called a weight. It now
  reads "Quantity received (pcs)". Filament orders still ask in grams, and now do so
  once rather than twice.

### Added

- **Consumables now reach the reorder list and purchase orders.** Running out of
  glue, isopropyl, bags or screws stops a job exactly the way running out of
  filament does, but only filament was ever forecast or ordered — a consumable
  that ran low said so in a toast that vanished, and nothing downstream heard
  about it. Reorder suggestions now include a consumables section, with usage
  worked out from the three ways stock is actually deducted (per print hour, one
  per packed order, and bill-of-materials components), and those suggestions can
  be drafted into purchase orders alongside the filament ones.

  Quantities stay in your own unit throughout — boxes are ordered and received as
  boxes, never as grams — and a received consumable order restocks the consumable
  and is recorded as general spend rather than as filament, so it no longer
  distorts the material cost that pricing is built on.

### Changed

- **Khayt now runs on Electron 42.8.1**, up from 42.2.0 — six patch releases
  inside the same major, so it carries upstream's Chromium and Node security and
  stability fixes without a behaviour change of its own. Nothing in the app was
  altered to accommodate it.

## [3.6.0-beta.15] - 2026-08-09

### Fixed

- **A planned BedReady maintenance window no longer looks like a broken sync.**
  While BedReady applies a database migration it closes every endpoint and says
  so, with how long to wait. Khayt reported that as "Library fetch failed (HTTP
  503)" — telling you your library sync was broken during a window in which
  nothing was broken and nothing was half-written. It now says BedReady is
  briefly unavailable and roughly how long, and your BedReady sign-in survives it
  rather than looking expired. A server that is genuinely misconfigured still
  reports as a failure, because that one will not fix itself by waiting.


## [3.6.0-beta.14] - 2026-08-09

### Added

- **Consumables can have categories, and you can look at one at a time.** A
  consumable had exactly one grouping — the packaging tick box — so screws,
  magnets, inserts, boxes and labels all sat in one flat list. Each item now takes
  a **Category** you type yourself, suggesting the ones you already use so the
  same shelf does not end up spelled three ways. A picker above the list shows one
  category at a time with a count beside each, and it only appears once you have
  more than one. Items you have not categorised are a group of their own rather
  than something that disappears the moment you filter — and if you empty a
  category while looking at it, the list returns to showing everything instead of
  going blank.

- **A fee can now be a percentage.** "Add fee" only ever took a fixed amount,
  which is the wrong shape for the fee that matters most: Etsy, Shopify and eBay
  charge a percentage, so quoting for them meant working it out on a calculator
  and typing the answer — then doing it again every time the price moved. Each
  fee row now has a **%** or currency switch. A percentage is charged on what the
  buyer actually pays, shipping and rush included, which is what those
  marketplaces charge against; it shows the money it works out to beside it, and
  it never compounds on another fee, so the order you type the rows in cannot
  change the total. Existing quotes are unaffected — a fee with no percentage on
  it behaves exactly as it always has.

- **Drop a .zip straight into your print files.** Model packs arrive as archives
  — a Drive download, a Patreon bundle — and Khayt could not open one: you had to
  unzip it yourself, into a folder, and drag the files in one at a time. Now the
  archive goes in and every STL, 3MF, OBJ or G-code inside becomes its own entry,
  exactly as if you had done that by hand. Anything else in the pack — the
  README, the licence, the render — is left alone and counted, so you know what
  was in there. Two files with the same name in different folders both arrive
  rather than one quietly replacing the other. And if a pack is too large to take
  in one go, Khayt says so instead of importing part of it and looking finished.

- **Rename a kit.** Kits could be created and disbanded but never renamed, so a
  name you regretted meant taking the whole thing apart and rebuilding it.
  **Rename** sits beside **Disband** in both apps. A name another kit already has
  is refused rather than quietly merging the two — that would move a different
  kit's prints on the strength of a typo. And renaming a kit whose definition was
  lost adopts it back, so prints can never be stranded in something with no name.

- **Kits reach Bed Ready.** Grouping several prints into one object was added to
  Khayt's orders list, which Bed Ready does not have — so the maker app now
  carries it on the home screen instead. Finished prints that are not yet in a kit
  are offered with a tick box; name them and they become one, with the whole
  thing's hours, grams and cost shown together and how far that ran from the
  slicer's estimate. A part you finish *after* making the kit can be added to it,
  which is the ordinary way a multi-part model actually gets printed. If some
  prints in a kit were never measured the total says so, and disbanding a kit
  puts the prints back on their own without deleting any of them.

- **Kits — several prints that are one object.** A figure printed as a head, a
  body and two legs is four separate jobs in your log, and until now nothing said
  they belonged together, so "what did that actually cost me" meant adding four
  rows up by hand. Tick those jobs in the orders list and choose **Add to kit**;
  a strip above the table then shows the whole thing — jobs, measured hours,
  grams and cost, and how far the total ran from the slicer's estimate. The jobs
  stay separate underneath, because each one's own measurement is what your
  estimates learn from; a kit only adds them up. If some jobs in a kit were never
  measured, the total says so rather than quietly leaving them out, and a kit
  spanning two currencies refuses to add them. **Disband** takes the jobs back
  out and leaves the prints untouched.


### Security

- **Khayt no longer has any way to read a message thread without proving the
  order is yours.** The previous release moved that read onto an authenticated
  route but kept a fallback to the old open one, for shops whose Khayt Cloud had
  not been updated yet. That fallback also caught the case where the order simply
  is not yours — and handed the conversation over anyway. It is gone, so the open
  route can now be closed on the server with nothing left depending on it. If your
  Khayt Cloud server is older than this build, the Messages panel now says so and
  tells you to update it, rather than quietly reading the thread another way.


## [3.6.0-beta.13] - 2026-08-07

### Security

- **Anyone with a portal link could read the whole message thread on it.** The
  customer's portal page reads its own conversation from a route that asks for no
  credentials, and it had to stay that way for one reason: Khayt's own "Portal
  messages" button read the very same route, with no token at all. Closing it
  would have blanked that button on every desktop in the field.

  Khayt now reads the thread as your shop — the server checks your token and that
  the order is yours, and refuses otherwise. Nothing changes on your screen; what
  changes is that the open route no longer has a reason to stay open, so the cloud
  can put the customer's sign-in in front of it, the same way sending a message
  already requires one. A shop whose cloud has not been updated yet still sees its
  messages: Khayt falls back to the old route when the new one is not there, and
  that fallback comes out in a later release.

### Fixed

- **Moving the print library no longer hides the files you already had.**
  Choosing a new library folder only ever changed where the *next* file went —
  and because Khayt lists files from the current folder and nowhere else, every
  record went from having models to looking empty. Nothing was ever deleted, but
  there was no way to tell that from the screen. Settings now spots files sitting
  in a folder the library has left, tells you how many and how large, and offers
  to bring them in. Each file is copied, read back and compared before the
  original is removed; nothing is overwritten, and anything that cannot be
  verified is left exactly where it is and reported. Khayt also remembers every
  folder the library has lived in, so moving it a second time no longer puts the
  first location out of reach.

- **A g-code file the shop re-sliced came back as a stranger, so quotes for it
  never learned.** Khayt recognises a print file two ways: by the file's exact
  bytes, and by its geometry. Re-slicing changes the bytes — so does simply
  exporting to a different name, because slicers stamp the filename and a
  timestamp into the header — and the geometry key was only ever worked out from
  a mesh, which a g-code file does not carry. So every re-slice of the same model
  arrived unrecognised, its finished prints were never pooled with the earlier
  ones, and per-file calibration never reached the three jobs it needs. Quotes
  fell back to the printer's overall average, which misprices anything unlike the
  shop's recent mix: measured against 16 real jobs, 21% under on a tall part and
  27% over on a flat one. Khayt now measures the shape the g-code actually prints
  — how wide and deep the material reaches through the object's height — which
  survives a change of layer height, infill or slicer version. Re-slice a model
  and Khayt offers the print file you already have, so its own measured history
  keeps building. It is offered as a likely match, never applied silently: two
  plaques of the same outer size can print different faces, and only you can say
  whether they are the same job.

### Added

- **Keep your print library on a network drive, an external disk, or a synced
  folder.** Your models were pinned inside Khayt's own data folder on one Mac —
  out of reach of the second workstation, and in the one place a backup routine
  never looks. Settings → Data & Locale → **Print library location** now lets you
  point it anywhere Khayt can reach: a mounted share, an external SSD, or an
  iCloud Drive / Dropbox / Google Drive / OneDrive folder. You can also set a
  second folder as a **backup**: every file added to the library is copied there
  too, and Khayt never reads from it, so the two can't quietly disagree about
  which is real. If the folder isn't reachable — share not mounted, laptop away
  from the shop — Khayt refuses to add files and tells you which folder is
  missing, rather than quietly starting a second library on the laptop. Files
  saved before you moved the library stay readable where they are.

- **Back the print library up to object storage.** Alongside a backup folder, you
  can now point Khayt at an S3-compatible bucket — Cloudflare R2, AWS S3,
  Backblaze B2, or anything else that speaks the same protocol — and every file
  added to the library is uploaded there too. Like the backup folder, Khayt never
  reads from it: it is an off-site copy, not a second library, so the two can't
  quietly disagree about which is real. **Test connection** actually writes a
  file, reads it back, checks the bytes match and removes it, so credentials that
  look right but can't write are caught now rather than at the first model you
  lose. Your secret key is encrypted on disk with the rest of Khayt's secrets and
  is never shown on screen again after you enter it.

- **An "Identify" button on print files Khayt cannot recognise.** Khayt only ever
  worked out what a file was at the moment you added it, so an entry that started
  without that could never gain it — and an unrecognised file is one Khayt can
  never match a part to, which is what keeps a model's own print history from
  pricing its next quote. The button reads the file and works it out now: if the
  entry already has a file it just re-reads it, and if it has none it asks you for
  one. It appears only on entries that need it, and tells you whether it managed
  to measure a shape or not.

- **3MF files are now recognisable too.** Khayt has always read a 3MF's size and
  shape to show you its figures, then thrown that measurement away — only STL
  files ever got something Khayt could match on later. A 3MF now gets the same
  one, from the same numbers, so the same model added once as a 3MF and once as
  an STL is recognised as one model instead of two.

- **Drop a model you have printed before and Khayt recognises it.** Linking a
  part to a file in your print library is what lets that file's own finished
  prints price the next quote, instead of the printer's overall average — which
  misjudges anything unlike your recent mix. The link was a dropdown nobody was
  prompted to touch, so in practice it stayed empty and the history never got
  used. Now, when you drop or pick a model, Khayt compares its shape against your
  library and selects the matching file for you, then re-prices using that file's
  measured history. It matches on the printed shape rather than the exact file,
  so a model you re-sliced at a different layer height or infill is still
  recognised. It only acts when exactly one file matches, never overrides a file
  you chose yourself, and tells you which one it picked so you can clear it — two
  plaques the same size on the outside can carry different faces, and only you
  can say whether they are the same job.


## [3.6.0-beta.12] - 2026-08-06

Mostly about telling you the truth when something did not work. Signing in to the
cloud stops asking you to wait for a code the server already failed to send, and
"Slice for exact quote" stops handing back a time with the weight left blank.


### Fixed

- **The filament library talked over itself, and could strand a keyboard user
  outside the dialog.** Searching announced a new total on every keystroke, so
  typing three letters read out three counts on top of each other — the count is
  now announced once you pause, and only when it has actually changed. Separately,
  pressing Install by keyboard disabled the button under your own focus, which
  dropped focus out of the dialog entirely: Tab then walked the page behind it.
  Focus now stays inside, and returns to the button if the install fails so you
  can retry.

- **"Slice for exact quote" gave you a print time but no weight.** Slicing a plain
  model — one that carries no printer or filament profile — leaves the slicer with
  no filament density, so it measures the volume exactly and then reports the
  weight as zero. Khayt was right to refuse a zero as a measurement, but that left
  the weight box empty on the one path meant to replace an estimate with a real
  number, and weight is what your material cost is priced from.

  The volume is the slicer's own measurement of the actual toolpaths, so the
  weight is now worked out from it using the filament density in your estimator
  settings. The note says when it was worked out that way rather than reported by
  the slicer, because those are different claims. A slicer that does report a
  weight is still believed over anything derived.

- **Khayt asked you to wait for a verification code the server had already failed
  to send.** The cloud server knows when the email provider refuses a message, and
  now says so; Khayt was not asking. It opened the "enter your code" dialog either
  way, so a shop whose provider had turned the message away sat waiting for
  something that was never accepted, with nothing to tell them apart from a slow
  inbox. Verifying an address, resetting a password and creating an account now
  each say plainly when the email could not be sent, instead of sending you to
  wait for it.


## [3.6.0-beta.11] - 2026-08-04

Signing in to the cloud, when it goes wrong, now says what went wrong. Nothing
about quoting changes on this build.


### Fixed

- **Signing in to the cloud could sit on "Connecting…" for half a minute and then
  say nothing useful.** The check that asks whether the server is there used the
  same thirty-second budget as a full sync, so a network that quietly swallows the
  request — a firewall, a VPN, a proxy — left the app looking frozen before it
  gave up. It now gives that check eight seconds, and says which of the three
  things went wrong: nothing answered in time, something answered that is not a
  Khayt server, or the address is not a valid one. Those need different fixes, and
  "Server not reachable" pointed at none of them.

- **Waiting for an email verification code told you nothing while you waited.**
  The code is sent and the dialog then goes quiet, so anyone whose message lands
  in spam — or never arrives — has no way to tell waiting from broken. It now says
  the code can take a minute and to check the spam folder, names the address it
  comes from when the server reports one, and offers **Send it again** without
  making you close the dialog and start over.


## [3.6.0-beta.10] - 2026-08-04

The estimator stops pretending it knows one number. Grams-per-hour was learned
once for the whole shop and used for everything — but measured across 67 finished
jobs on a single printer it ran from 1.9 to 48.6, because it follows the part far
more than the machine. So a model you have printed before is now priced from its
own prints, and the rate is reported as the middle of your jobs with how far they
disagreed, rather than as something your printer does.

**Quotes for unsliced models move again on this build**, for a different reason
than they moved in beta.9 — see [docs/BETA-RELEASE.md](./docs/BETA-RELEASE.md).


### Added

- **A model you have printed before is priced from its own prints.** Khayt learned
  one rate for the whole shop, and used it for everything. That is the wrong shape
  for the number: across 67 finished jobs on a single printer it ran from 1.9 to
  48.6 g/hour, because it follows the part's geometry, layer height and colour
  changes far more than it follows the machine. A shop-wide average therefore
  describes your recent *mix* of work, and misprices anything unlike it.

  When you tell the calculator which model this is — the **From your print
  library** picker — Khayt now uses that model's own finished prints instead, and
  the settings you printed it with if you name those too. It falls back on its own:
  this model with these settings, then this model, then this printer, then the
  shop, taking the first that has three measured prints behind it and agrees with
  itself. The note says which you got, so a rate from three prints of this exact
  model never reads like an average of everything.

### Changed

- **The estimate note no longer states your printer's rate as though it were a
  specification.** It said "27.4 g/h — measured from 12 finished jobs on this
  printer", which reads as something the machine does. It is not: measured across
  67 finished jobs on one real printer, grams-per-hour ran from 1.9 to 48.6
  depending on what was being printed — it follows the part's shape, layer height
  and colour changes, not the machine. Over the same jobs the slicer's own time
  estimate held to about 5%.

  The rate is now given as what it actually is — the middle of your finished
  jobs, with how far they disagreed: *"26.3 g/h — the middle of 12 finished jobs
  measured on this printer, give or take 12%."* The number has not changed. What
  changed is that you can now see how much of a number it is before you quote
  against it.

### Fixed

- **A printer could report negative hours since its last service.** Adding a
  printer that already had hours on it — typing what its own screen said into
  "Hours at last service" — produced readings like "-200.0h since service" on the
  machine card. The app was subtracting a number off the printer's clock from a
  tally it had started counting at zero on the day the printer was added.

  The reading is now the hours actually run since the service, counted from when
  the service was recorded, so it is right whichever clock the number came from.
  It also fixes the quieter half: because the old figure never climbed to the
  service interval, the service-due reminder for such a printer could never fire.

- **Bed Ready's sidebar showed two headings with nothing under them.** "Catalog"
  and "Money" sat below the nav on every screen, labelling empty space. The themed
  sidebar builds those groups and moves the app's nav buttons into them; Bed Ready
  has no catalogue, clients, order log or expenses to move, so the groups were
  built, given nothing, and drawn anyway. They are now hidden when there is nothing
  to show, and reappear if there ever is.

## [3.6.0-beta.9] - 2026-08-03

Mostly one bug wearing three faces. The calculator was pricing every unsliced
model on numbers that were not the shop's — not its filament density, not its
infill, and not the rate its own printers had been measured at — while the
customer-facing intake form had been using the real ones all along. So the same
file could come back from a customer and from the shop's own screen with two
different answers, and the shop's was the wrong one.

The estimate note now says which rate it used, whether anyone measured it, and
which printers earned it. **Quotes for unsliced models will move on this build**
— see [docs/BETA-RELEASE.md](./docs/BETA-RELEASE.md) before sending one.

Also closes a converter write gate that checked destinations against the list of
folders it was allowed to *read*.

### Security

- **The converter could be made to write a file anywhere the app could read.** The
  3MF converter takes a destination from the screen when it converts a batch, and
  checked that destination against the list of folders it is allowed to *read* —
  which includes Documents, Downloads, the desktop and the app's own data folder.
  So a destination it should have refused was accepted: any folder on that list,
  any filename, any extension, with no save dialog shown, including next to the
  file the app keeps your shop data in.

  Reaching it would take a compromise of the app's window first, which is sandboxed
  and cannot reach the filesystem on its own — but keeping file writes on the other
  side of that boundary is the whole reason they live there. Writing now requires
  consent for that specific destination: either you chose it in the save dialog, or
  it is inside the output folder you picked for a batch. Symbolic links out of an
  approved folder are resolved and refused.

### Fixed

- **Packaging Bed Ready could leave the source checkout broken.** The Bed Ready
  build swaps the project's version file for the duration of the build and puts it
  back afterwards. electron-builder rewrites that same file while packaging, using
  helper processes the build does not wait for — so one could land after the file
  had already been put back, and the build would report success and finish with the
  file still rewritten. Nothing looked wrong until the next command in that checkout
  failed for no apparent reason. The build now keeps watching after it restores,
  puts back anything that moves, and stops with a clear message naming the file if
  it cannot. Affects contributors building from source, not anyone using the app.
- **A beta build could not find its own updates.** Bed Ready ships on a beta line,
  and every release on it is marked pre-release on GitHub. An app that refuses
  pre-releases is answered with the newest release that *isn't* one — which, on a
  line made entirely of betas, is older than what is already installed, or nothing
  at all. So the app either sat on "you're up to date" while newer builds existed,
  or reported that there were no published versions with the release sitting right
  there, assets and all.

  The intent was already in the code — a beta build was meant to accept beta
  updates — but the preference the app sends a moment after startup, which is off
  by default, landed on top of it and switched it back off every time.

  A build that is itself a pre-release now always accepts them, whatever the
  preference says, because nothing else can ever be an update for it. The
  preference keeps its meaning for a stable build deciding whether to follow the
  beta lane — and a stable build is no longer offered the beta it succeeded.

- **Your default infill was used to quote your customers, but not you.** The
  calculator's own infill box starts empty, and an empty box fell back to a fixed
  20% instead of the *Default infill %* you set under Settings → Preferences. A
  shop set up for 60% had every dropped model quoted at 20% — around a third less
  material than the part really takes — while the customer intake form, which
  reads the setting directly, quoted the same file at 60%. The two now agree, and
  a figure you type for one part still takes precedence for that part.

- **Changing the infill or the printer after dropping a model changed nothing.**
  The estimate was worked out once, when the file landed, and never again. Set the
  infill to 90% afterwards and the form showed 90 beside a note still insisting on
  20%, with the price built on the figure you could not see. Choosing the printer
  after dropping the file was the same: a machine with its own measured rate was
  ignored until you dropped the file a second time. Both now recompute, quietly,
  and the note always describes the numbers actually in the form.

  Figures that came from a slicer are left alone, so a weight you corrected by
  hand survives; and adding the part to the quote now clears the estimate with it,
  rather than leaving a note describing a part that has already moved on.

- **Saving a converted model outside your home folders was refused.** The same
  conflation ran the other way: the STL and 3MF exporters checked the path you had
  just typed into the app's own save dialog against that read list, so saving to an
  external drive, a network share, or any folder outside Documents, Downloads and
  the desktop failed with "Output path is outside an allowed folder" — your own
  choice, denied. Where you choose to save is now yours.

- **The calculator ignored your estimator settings, and everything it had
  measured.** Drop an unsliced model on the calculator and Khayt priced it on the
  numbers it ships with — PLA at 1.24 g/cm³ and a throughput of about 35.7 g/hour
  — no matter what you had set. The settings panel saved your density, your wall
  thickness and the rate worked out from your own finished jobs, and read them
  back correctly; only one field, the infill, ever reached the file you dropped.

  A shop that had measured its printers at 12 g/hour was still quoting every
  unsliced part at roughly half the print time it would really take. The public
  intake form your customers use was never affected — it always priced on your
  settings — so the same file could come back from the customer form and your own
  calculator with two different answers.

- **A printer's measurements could be lost before anyone looked at them.** Khayt
  reads what a job actually used at the moment it finishes, because the printer
  resets those counters when the next one starts. It kept only the most recent
  one per machine — so a second job finishing overnight, or on another printer,
  erased the first, and the dialog still offered a confident *Measured* figure
  belonging to a different print.

  It now remembers the last eight, and an order that recorded which file it
  printed is offered that job's figures rather than simply the latest.

- **Pausing a print was recorded as finishing it.** Khayt froze the filament and
  duration on the way out of *printing*, and a pause leaves that state too — so a
  paused job's part-way numbers were kept as though the job had ended. They were
  overwritten when it really finished, which is why nothing ever looked wrong.

- **A stuck conversion left the app waiting forever.** A converter process that
  crashed was reported; one that simply stopped responding was not, so the window
  waited on an answer that was never coming, with no error and no end. It now
  gives up after thirty minutes, says the converter stopped responding and that
  nothing on disk was changed, and starts a fresh one for the next file.
- **Bed Ready could not put a job on its own production queue.** The calculator's
  primary button says "Add to print queue". It was wired to `logPrint()`, which
  lives in the business-only module Bed Ready does not ship, so the shim had
  declared it a no-op: the button rendered, the click landed, and nothing
  happened. That function holds the only code path in the app that ever creates
  an order, which made the queue, the machine strip and the dashboard's "prints
  done" all features of a screen that could never have anything on it.

  The same was true of every other button on a queue card — hold, QC pass, QC
  fail, mark delivered, timeline, print label and capture failure photo. None of
  them is a commercial action, all of them render for makers, and all seven
  handlers lived in that same business module. Eight live controls, all silent.

  Bed Ready now has its own, built from what it actually collects: a job carries
  its parts, its machine and a due date estimated from queue depth, and each card
  action routes through the existing queue transition so WIP limits, the live
  timer, the filament deduction and the undo all still apply. A failed QC books
  the wasted filament into the waste log and sends the job round again.

  A stub is still a function, which is why `typeof fn === 'function'` never
  caught any of this. A new test now checks the wiring itself, and makes a newly
  added queue-card button fail until someone decides whether Bed Ready shows it.

### Changed

- **Bed Ready no longer calls itself a beta.** The BETA badge beside the wordmark
  is gone, along with the "This is a public beta" section in Help and the beta
  wording on the Feedback button. The safety and no-warranty text stays exactly
  where it was — that was never beta copy — and the Help tab it lives in is now
  "Disclaimers & credits".

  The badge next to the version number is untouched: it reads the running version
  and labels a build "Beta" only when the version itself says so, which stays
  honest on either line.

- **The estimate note now says whether the rate was measured or assumed, and by
  which printers.** It reports the grams-per-hour the time was built on, and
  either says plainly that nothing has been measured yet, or names the jobs
  behind it — *on this printer* when the part is assigned to one that has its own
  history, and *across your printers* when the figure is pooled from the rest of
  the shop. The second is the same number making a weaker claim, and it no longer
  reads like the first.

## [3.6.0-beta.8] - 2026-08-03

Mostly one file's worth of consequences. A 229 MB Spider-Man poster that would
not convert turned out to be sitting on top of a converter that could lose part
of a model without saying so.

### Fixed

- **A large 3MF could convert into a model missing most of itself.** Khayt caps
  how much it will unpack from a 3MF so a crafted file cannot exhaust memory.
  When a real project crossed that cap, the converter dropped whole objects —
  240 MB of geometry in one case — and reported success.

  A model short an object still opens, still slices and still prints. It simply
  is not what the maker chose, and nothing anywhere said so. A read that cannot
  keep everything it was given now refuses and explains, rather than quietly
  writing out a smaller model. The file that prompted this also stopped being
  rejected for its size, which was the complaint that led here.

- **The converter stopped the app while it worked.** That work ran on the only
  thread Electron has for windows, menus and IPC, so a large retarget left the
  window unresponsive and macOS marking the app as not responding — for minutes.
  A shop watching that force-quits, which looks exactly like the conversion being
  broken.

  Conversions now run in a separate process. They also got much faster: meshes
  were being unpacked and repacked at maximum compression to reproduce bytes the
  file already contained, and normalizing never reads them. A convert that took
  106 seconds takes about 8.

- **The HueForge panel could describe the filament stack you just changed.**
  Adding, deleting, reordering or auto-tuning a filament repainted the rows
  without recomputing what depends on them, so the achievable-colour preview,
  the swap elevation and the U1 verdict kept describing the previous stack.
  Editing a TD or a layer count always refreshed correctly, which is why this
  survived.

- **Bed Ready: two features were present, wired up, and did nothing.** Matching a
  model you already have never matched, and the saved-settings button on every
  file card was dead. Both libraries ship in Bed Ready; one screen reached for
  them in a way that only worked in Khayt, and nothing errored.

### Added

- **HueForge FLAT mode — colour by region instead of by height.** On a
  toolchanger that does not purge between tools, flat multi-colour is nearly
  free, and it avoids relief printing's whole problem class: no surface texture,
  no transmission physics, no TD calibration. Quantize to four colours, give each
  region a head.

  **Not yet proven on a printer.** The generated 3MF is verified by reading the
  written archive back out rather than by trusting the code that produced it, and
  `scripts/flat-test-plate.mjs` will build a real plate to try. Treat it as
  ready to test, not ready to rely on.

## [3.6.0-beta.7] - 2026-08-02

Three things a shop will notice, and two of them came from real files and real
installs that did not work.

### Fixed

- **A big multi-colour 3MF could open as if it had no colours at all.** Khayt
  reads a 3MF's members up to a size limit, so a malicious file cannot exhaust
  memory. It read them in the order the file happened to store them — and in a
  229 MB six-colour project the two small files that say *which slicer made this
  and which filaments it uses* were stored last, behind every mesh. The limit
  ran out before reaching them.

  The file then looked like a plain, colourless model: nothing to convert, and
  no error, because every step had done its job on what it was handed. Khayt now
  reads those few kilobytes first and the meshes afterwards. The size limit is
  unchanged.

- **An update check could show a file path instead of an explanation.** A build
  made for local testing carries no update information, and asking it to check
  produced a raw `ENOENT ... app-update.yml`. It now says the install cannot
  update itself and where to download a build that can — which Khayt already
  knew how to say, and only ever said on Linux.

### Changed

- **The production queue opens on the board.** Khayt has always had the kanban
  the website shows — drag a job from Pending to Printing and it moves — but
  every theme opened on the grouped list, with the board behind a toggle nobody
  is told about.

  The board is now what you get, in every theme. If you prefer the list, switch
  once and it stays switched — including for shops that already chose it.


## [3.6.0-beta.6] - 2026-08-02

One change you will see, and it exists because two prints ran back to back —
which is an ordinary day in a shop and something no test had ever imagined.

### Fixed

- **A measured figure now says which print it was measured on.** When you log a
  finished job, Khayt offers the filament and time its printer actually
  recorded, marked *Measured*. It named the printer those numbers came from —
  but not the job.

  Khayt keeps a finished job's figures available for a day. If you start
  another print in that time, and most shops do, the numbers waiting on screen
  can belong to the previous one. Marked *Measured*, in green, with nothing to
  tell you they were someone else's.

  It now names the file: "measured on bracket.gcode". If that is not the job in
  front of you, you can see it at a glance.

  This matters past a single order. Khayt learns how fast your printers really
  run from the figures you confirm, so a number attached to the wrong job does
  not just mis-cost that job — it teaches Khayt something untrue.

  The day-long window is unchanged. Refusing an older measurement would cost a
  shop a good number when they log yesterday's print, and that is a separate
  decision from simply showing you what you are looking at.

### For maintainers

- The completion capture — the code deciding whether a measured cost ever
  reaches an order — is now tested against a print that really finished, rather
  than against figures somebody typed. Recorded by polling a Snapmaker U1 every
  20 seconds across a five-hour job and keeping the samples either side of the
  moment it stopped.

  One thing only the real data showed: the last reading *while still printing*
  already said 100%. Anything trusting progress instead of state would capture a
  cost mid-job and never capture the true one.

- The Snapmaker U1 catalogue entry is pinned to what the machine itself reports.


## [3.6.0-beta.5] - 2026-08-02

Two fixes to the files Bed Ready sends a Snapmaker U1, both found by opening a
3MF the printer was actually printing and comparing it with one Khayt had made.

### Fixed

- **The top colour was dropping out of the print.** Khayt ended the last colour
  band at the model's exact height. Any layer landing on that boundary belonged
  to no band at all, so the printer fell back to its default — the base colour —
  and the top of the piece came out in the wrong filament.

  Nothing warned about it. The file opened, sliced and printed; it just printed
  wrong, and on a relief the top layers are the picture. A working export leaves
  its last band open-ended, and Khayt now does the same.

- **Prints took about twice as long as they needed to.** The base of a relief is
  solid and opaque — it exists to stop the bed showing through, and nothing about
  it is visible in the finished piece. A real export prints it in thick layers
  and switches to fine ones only where the colours blend. Khayt used the same
  fine layer everywhere.

  For the piece this was measured against: 28 layers as the printer's own
  software sliced it, 57 the way Khayt would have. The base now prints at twice
  the layer height, capped so it stays within what a standard nozzle can lay
  down, and never coarser than the colour bands above it.

### For maintainers

- First tests for `lib/hueforge-3mf.js`, all measured against that real export
  rather than an invented shape. `lib/hueforge.js` gained tests in beta.4; its
  mesh geometry proved correct.


## [3.6.0-beta.4] - 2026-08-01

A small one, and only for Bed Ready. Two settings that Khayt would accept
without complaint and then quietly build an unprintable plan from.

### Fixed

- **A layer height of "infinity" was accepted.** Typing something like `1e999`
  into the layer-height box gave a number JavaScript treats as infinite, and the
  check guarding that box only asked whether it was above zero. Every colour in
  the resulting stack came back at an infinite height: nothing failed, nothing
  warned, and the plan described a print that cannot exist. It now has to be a
  real number.

- **A filament's opacity could be worked out from a non-number.** The same shape
  of gap one step deeper: the guard on layer thickness caught negatives but let
  a non-number through, which would have turned every blended colour into
  nonsense. Nothing in the app could reach it — the layer-height check above
  stops it first — but the function is available to other code, so it now
  defends itself.

### For maintainers

- `lib/hueforge.js` has tests for the first time: 434 lines and fifteen exported
  functions that nothing had ever exercised. The mesh it generates turned out to
  be correct — every test heightfield produces exactly the volume its shape
  implies, checked against Khayt's own STL reader, and the output slices cleanly
  in PrusaSlicer.


## [3.6.0-beta.3] - 2026-08-01

Found by pointing Khayt at a Snapmaker U1 that was actually printing. Everything
here is a fix to what Khayt showed about a live job — none of it was reachable
without real hardware in front of it.

### Fixed

- **A five-hour print was shown as 1% done, with 178 hours remaining.** Khayt
  read a Klipper printer's progress from how far through the *file* it was.
  Bytes are not work: on a detailed model most of the instructions sit in the
  upper layers, so the file barely moves for the first third of the print. On a
  real job 65 minutes in — genuinely about a fifth done — Khayt said 1%.

  It now counts layers, which the printer was already reporting in the same
  reply Khayt was reading. The same job then showed 18% with about 5 hours left,
  against roughly 4 hours 15 remaining in reality.

  The remaining time is also worked out from time spent *printing* rather than
  time since the job was sent, so heating and idling no longer inflate it.

- **A Klipper printer could be set up as the wrong kind of printer.** Klipper's
  Moonraker pretends to be OctoPrint so that OctoPrint-only slicers can send it
  files, and Khayt's printer search reported one machine as three different
  makes. Choosing the wrong one looked fine and quietly recorded nothing: that
  compatibility layer reports no filament and no print time, so every finished
  job would have come back empty. The search now names the real one.

### Verified against hardware

- **What a finished job cost is now confirmed against a real printer.** The
  figures Khayt reads back — filament used, time spent — had only ever been
  checked against hand-written examples, which can agree with a mistake
  forever. Read live, mid-print, from a Snapmaker U1 on stock firmware: every
  field correct. Stock firmware is enough; no custom firmware needed.


## [3.6.0-beta.2] - 2026-08-01

Fourteen commits landed after beta.1 was cut, and two of them change numbers you
or your customers see. If you are running beta.1, update — the quoting fix below
is the reason this exists.

### Fixed

- **Large parts were quoted for far more filament than they use.** The estimator
  treated a part's walls as a fixed 35% of its volume. Walls follow a part's
  *surface*, so their share has to fall as the part gets bigger — a constant
  cannot be right at two sizes at once. It was about right at roughly
  calibration-cube size and wrong either side of it: a 100 mm part was quoted at
  613 g against a physical ~327 g, and a 200 mm one at more than double.

  Measured against PrusaSlicer, the customer's price on a 100 mm part falls 24%,
  and on a 200 mm part 47%. That is a correction rather than a discount — the
  old figure billed for filament that would never be extruded.

  Nothing would have caught this on its own: estimate calibration only ever
  learns print *time* from finished jobs, never weight.

- **Khayt now says when a model is one it cannot price.** Scored against a real
  slicer, the geometric estimate lands within about 13% on ordinary parts and
  falls apart on very thin or very detailed ones — a flat plate came out 58%
  high, a HueForge-style relief 66% low, because a printer lays a minimum bead
  of plastic however fine the detail is. Those now carry a clear warning to the
  shop, and the customer's page says the shape is hard to price automatically
  instead of showing a confident number that is badly wrong.

  It deliberately warns a little too often. Being told to slice a part you could
  have quoted costs a minute; quoting a job at a third of its cost does not.

### Security

- **The brute-force lockout never actually locked.** Ten wrong LAN PINs were
  supposed to block an address for a minute; the counter reset on every attempt,
  so it never got there. Also shipped as v3.5.3 for the stable channel — see
  that entry for the full account.

### Added

- **Khayt can ask a printer what camera it has**, instead of guessing addresses
  from convention. Moonraker and OctoPrint both publish this; Khayt could read
  both replies and had never asked. On a Snapmaker U1 this is the difference
  between stock firmware (no camera registered) and the community extended
  firmware (a real one).

- **A Help menu**, which the app did not have — website, community, release
  notes and a link to report a problem.

### For maintainers

- `npm run verify:estimator` slices a spread of shapes with a real PrusaSlicer
  and prints Khayt's estimate beside the truth. That is where the percentages
  above come from.


## [3.6.0-beta.1] - 2026-07-31

Khayt learns what your prints actually cost, and uses it.

Until now every part of that was a guess in isolation: the calculator estimated,
the job finished, and nothing connected the two. This release joins them. A model
becomes a quote, the printer reports what the job really used, the settings that
produced it are remembered against the file, and the estimator quietly corrects
itself from your own finished work.

This is a beta. It changes what customers are quoted and how every
geometry-based time estimate is worked out, so it goes out for soaking before it
becomes the default download.

### Added

- **Drop a model on the calculator and get a quote.** One drop zone takes STL,
  OBJ, 3MF or G-code. If you already sliced the file, Khayt reads your slicer's
  own time and filament figures — those are exact, and it says so. If nobody has
  sliced it, it works the weight and time out from the model's shape and labels
  that plainly as an estimate, because on a sparse or heavily supported part it
  can be well out. The two are never presented the same way.

- **Your customers can price their own model.** Optional, and off until you turn
  it on: Settings → Online → *Let customers price their own model*. It adds a
  file upload to your intake form and shows an indicative figure, worked out with
  your own printer preset, material and margin. The file is priced in memory and
  never stored. The customer is told the figure is not a confirmed quote, and you
  see what they were shown on the request when it arrives.

- **Khayt learns what a print actually cost.** When a job finishes on a Moonraker,
  OctoPrint or Duet machine, Khayt reads the real filament used and the real print
  duration from the printer and offers those figures when you mark the order
  complete — instead of offering your estimate back to you, which is what it used
  to do. PrusaLink reports the duration but not the filament, so you get the time
  measured and the weight left to you. Bambu reports neither. Each field says
  which it is, so a measured figure and an assumed one never look alike.

- **Settings that worked, remembered.** A print file can now keep the setups you
  have printed it with — printer, material, colour, layer height, nozzle — each
  with its own record of how the prints went. The file shows which one to reach
  for. A setup that has never failed beats one that merely gets used a lot, and
  if every setup has failed Khayt says so rather than recommending the least bad
  one.

- **Khayt recognises a file you already have.** Add the same model twice and it
  tells you, names the copy you already own, and offers to drop the duplicate —
  because the one you have carries its print history and its known-good settings,
  and a fresh copy carries none of that. A file that merely looks like one you
  have is described as looking like it, never as being it.

- **Estimates that correct themselves.** Once a few jobs have finished with
  measured figures, Khayt works out how fast your printers really run and uses
  that instead of a built-in assumption. That assumption was optimistic — it
  implied a sustained rate well above what typical printing achieves once travel
  and acceleration are counted — so time estimates for unsliced models tended to
  come out short. Settings → Preferences shows the rate and says whether it was
  measured or assumed.

- **A part can point at the model it prints.** Pick a file and a setup on the
  calculator, and finishing that order records how it went against those settings
  automatically. Over time this answers the question estimating never could: for
  this part, with these settings, how far out am I?

- **Browsing the Bed Ready library.** Search, filter by file type, sort, and
  download or add a single design instead of all of them.

- **Elegoo resin printers.** The protocol layer for Mars and Saturn machines
  (SDCP v3.0.0). Groundwork — nothing to connect to yet.

### Fixed

- **3MF files never gave up their slicer figures.** "Parse from file" appeared to
  work on a 3MF and filled in nothing, every time. A 3MF is a compressed archive
  and Khayt was reading it without unpacking it, so the time and filament
  summary your slicer wrote was never found. If you gave up on that button, it
  works now.

- **Bambu and Orca print times were being dropped.** Khayt read the filament
  weight from a Bambu or Orca 3MF but silently never read the print time, because
  it was looking for it in the wrong shape.

- **Estimator settings were fixed values.** Filament density, default infill,
  wall fraction and waste were the same for everybody — a shop printing PETG at
  40% infill had its estimates built on PLA at 20%. They are now yours to set,
  under Settings → Preferences, and they default to what Khayt always used.

- **"Actual" figures were pre-filled with your estimate.** Marking a job complete
  offered your own estimate back as the actual, so confirming it recorded the
  estimate twice under two names — and the estimate-vs-actual report then said
  your estimate was spot on for a job that ran two hours long.

### Changed

- **A part's file reference can be a real link.** The free-text file field is
  still there; alongside it you can now pick from your print library, which is
  what lets a finished job teach the file it printed.


## [3.5.3] - 2026-08-01

A security fix. Khayt's LAN server locks out an address after ten failed
sign-in attempts — except it never did. The lockout has been inert since
v2.2.5, so anything protected by your LAN PIN could be guessed at as fast as a
machine could ask.

Nothing about your data changed, and there is no sign this was used against
anyone. Update anyway if you have ever switched the LAN server on.

### Security

- **The brute-force lockout never engaged.** Khayt counts failed attempts per
  address and blocks that address for a minute after ten. The counter reset
  itself on every attempt, so it sat at one forever and the block was never
  reached — it could not lock out because it never counted, and it never
  counted because it was not locked out.

  In practice that left a four-digit LAN PIN — ten thousand possibilities — in
  front of your clients, orders, inventory and machines with nothing slowing
  down the guessing. On a shop network, someone already on your Wi-Fi could
  work through every PIN in seconds.

  Five separate protections had the same fault and all five were affected: the
  LAN PIN on both reading and writing, the customer intake PIN, API tokens, and
  the check that rejects forged shipping and store webhooks.

  The lockout now works: the eleventh wrong attempt is refused, and stays
  refused for a minute. If you share a network and someone mistypes the PIN ten
  times, expect a one-minute wait — that is the feature working.

  **If your LAN PIN is short, change it.** Settings → LAN API. The lockout
  helps, but a longer PIN is what actually protects you, and it costs nothing.

> Cut from the `release/3.5.x` maintenance branch, not from `main` — `main`
> was already at `3.6.0-beta.1`, and stable users needed the security fix
> without the unsoaked estimate-to-actual work that came with it.

## [3.5.2] - 2026-07-30

Two places where Khayt showed a customer a currency that might not be the one
your shop prices in. Both are on pages a customer sees; neither affects your own
figures, and no stored data changed.

### Fixed

- **The order request form asked for a budget in SAR, whatever currency you use.**
  The budget ranges on the intake form your customers fill in read "Less than
  100 SAR", "100 – 500 SAR" and so on — fixed text, not something your settings
  could change. If your shop prices in anything else, every customer who opened
  that form was choosing a budget on the wrong scale, and the range you received
  meant something different from what they picked.

  The ranges now use your shop's currency. The choices themselves are unchanged,
  so requests you have already received still read exactly as before.

- **A quote could show a customer the wrong currency.** The quote approval page —
  the one a customer opens to accept a price — fell back to SAR when it could not
  read your shop's currency setting. It now shows the amount without a currency
  in that case rather than naming the wrong one. This needed an unusual store to
  happen at all; if your quotes have looked right, they were.

## [3.5.1] - 2026-07-30

The half of organisations that 3.5.0 described but did not include.

### Added

- **Across the branches.** Settings → Khayt Cloud → Organisation → *Across the
  branches*. Enter your organisation passphrase and Khayt shows each branch: how
  much work is in flight, how much is printing or on hold, quotes waiting, and
  when that branch last changed anything.

  The passphrase is asked for each time and never stored, so the key that opens
  every branch is not sitting in memory all day for a screen you open now and
  then.

  Branches are read one at a time. If one has not synced yet, is still being set
  up, or cannot be opened, it says so on its own line and the others still appear
  — and the totals tell you how many were left out rather than quietly counting
  them as zero.

  **What it does not show, on purpose.** No money: revenue is not simply the sum
  of order prices — voided invoices, refunds and credit notes all subtract — and a
  second way of adding it up would give you a chain total that disagrees with what
  each branch reports, with no way to tell which is right. And no "due today": a
  branch may be hours ahead of or behind you, so a day boundary means different
  things in different places. What you get instead are counts that mean the same
  thing everywhere, and the branch's own last-change time in your language and
  time zone.

  These figures come from each branch's last sync, not from its screen at this
  moment — the view says so too.

## [3.5.0] - 2026-07-30

**If you enabled the operator lock, please read the fix below** — the recovery
code Khayt showed you was being wiped off the screen before you could read it.

### Added

- **Organisations: set up one passphrase for every branch.** If you run more than
  one branch, each has had its own sync passphrase, so opening four branches meant
  remembering four. An organisation gives you one passphrase for all of them.

  Settings → Khayt Cloud → Organisation. Create one, then add each branch with a
  code you paste into that branch's copy of Khayt.

  **This release is the setup, not yet the payoff.** You can create an
  organisation, add branches to it and unlock them all with one passphrase — but
  there is not yet a screen that shows you another branch's orders or figures. So
  today this saves you passphrases, and nothing more. A view across your branches
  is the next piece of work; the entry above originally implied it was already
  here, which it is not.

  **Your branches keep everything they already have.** The organisation
  passphrase is a second way in, not a replacement: each branch's own passphrase
  and its recovery key keep working exactly as before, including a recovery key
  you printed and filed years ago. Removing a branch from an organisation only
  closes the organisation's way in — that branch is untouched otherwise.

  The organisation has its own recovery key, shown once, for the whole
  organisation. Khayt cannot recover it for you.

  What this does not change: removing a device still stops it connecting and
  receiving anything new, but does not erase what already reached it. With an
  organisation that reaches every branch rather than one, which is why the
  removal dialog says so plainly.

### Fixed

- **The operator-lock recovery code was wiped before you could read it.** Turning
  on the operator lock shows a recovery code — the only way back in if the PIN is
  forgotten — and the window it appeared in was being cleared the instant it
  opened. Nothing looked wrong; the code simply never appeared. If you turned the
  operator lock on and never saw a code, that is why.

  To get one: Settings → Security → **New recovery code**. It asks for your PIN
  and then shows a fresh code; that button was never affected. Don't switch the
  lock off to fix this — switching it off also clears your operator list.

## [3.4.2] - 2026-07-30

A correctness release for shops that sync across **three or more devices**. If
Khayt Cloud is off, or you run it on one or two machines, nothing here changes
for you and there is no urgency in updating.

**A deleted order, client or spool could come back.** When one machine deleted a
record and a second machine received that delete, the second machine removed the
record but kept no note that it had been deleted. Any third machine that had not
yet caught up still had the record, and offered it back — and with nothing to
refuse it with, the second machine took it. The machine that pressed delete kept
its own note and stayed correct. So two machines ended up disagreeing about what
existed, quietly, with no way for either to notice.

Deletes are now remembered by every machine they reach, not only by the one that
made them, so the machines agree again.

**If this already happened to you, this release does not undo it.** A record that
came back is an ordinary record now, and Khayt cannot tell it apart from one you
meant to keep — deleting it for you weeks later would be a second silent change on
top of the first. Khayt already tells you when a record reappeared on the machine
you deleted it from. It cannot see the other case, where a machine simply held on
to something it should have dropped, so it is worth a look through anything you
deleted and did not expect to see again.

### Fixed

- **A delete could be undone by a machine that had not seen it yet.** Applying an
  incoming delete removed the record without recording that a delete had
  happened, so the receiving machine had nothing to stop a third machine putting
  it straight back. Affects Khayt Cloud sync across three or more devices on
  3.3.0 and every 3.4 release. Two-device shops were never affected — the only
  machine that could offer the record back was the one that deleted it.

- **A machine that was behind never learned about deletes at all.** A delete for
  a record that machine had not yet received was discarded outright rather than
  remembered, which is exactly how it stayed out of step: it would go on offering
  the record to everyone else.

### Added

- **Organisations (groundwork).** A shop group can hold one key that opens every
  branch, so an owner unlocks once instead of remembering a passphrase per
  branch. Each branch keeps its own key, so holding one branch's key still reads
  only that branch, and a branch's existing recovery key keeps working exactly as
  before. Not yet reachable from the interface — this release only lays the
  groundwork.

### Changed

- **Removing a team member now says what that does, and what it does not.** It
  stops that device connecting or receiving anything further. It does not erase
  what already reached it, and the dialog no longer leaves you to assume
  otherwise.

## [3.4.1] - 2026-07-29

A repair release for one platform. If you are on macOS or Windows, 3.4.0 already
reached you and there is nothing new here.

**Linux installs could never update themselves.** Khayt's Linux builds went out
without the small file the updater reads to learn what the latest version is, so
the check that runs at every launch had nothing to find. It has been that way
since 3.2.0 — anyone running the AppImage has been sitting on whatever version
they first downloaded, with no sign anything was wrong.

This release is the first to publish that file, which means **3.4.1 still has to
be installed by hand**; from here on the AppImage will offer updates by itself.


### Fixed

- **Linux never received automatic updates.** Khayt's Linux builds were published
  without the small file the updater reads to find out what the latest version
  is, so the check on every launch could not succeed and no update was ever
  offered. It has been this way since 3.2.0 — if you installed the AppImage, you
  have been on whatever version you first downloaded. Fixed from the next release
  onwards; this one still has to be downloaded by hand.

- **A `.deb` install said "you're up to date" when it wasn't.** Only the AppImage
  can replace itself, but the check did not know that and reported the same
  answer as a genuine no-update-found. It now says plainly that this install
  cannot update itself, and points at the download page.


## [3.4.0] - 2026-07-29

The 3.4.0 beta line, released as stable. Individual beta entries are kept below;
this is what changed for you since 3.3.0.

Three things, and they are unrelated except that each one was invisible until
somebody looked.

**Khayt now speaks your language properly.** Brazilian Portuguese joins as a
complete translation — all 3,675 phrases — making nine. More to the point, a
sweep found large parts of the app that had never been translated at all: a whole
Bed Ready feature, four settings sections, tooltips and placeholders everywhere,
and dates and times that ignored your choice of language in 49 of the 51 places
Khayt prints one. 205 dead phrases were removed across all nine languages, and a
check now fails the build when the app asks for a phrase no language has.

**Five new looks**, two of which are new ways to work rather than new colours —
including Flow, the first design where the job board *is* the home screen. The
existing designs got the attention they needed too: Meridian could not be
scrolled at all on a long screen, faint text was unreadable in every light theme,
and two designs lost their language picker on a narrow window.

**And the app was quietly wrong about dates.** Khayt worked out "today" from UTC
rather than from your own calendar, which is correct in London and wrong
everywhere else for part of every day. In Saudi Arabia that meant the first three
hours after midnight belonged to yesterday: an expired quote stayed approvable, an
order taken at 01:00 was dated into the wrong day's revenue, and a monthly expense
walked backwards a day every cycle. The same mistake counted months, so a budget
warning could total the wrong one.

Since the last beta, this release also fixes a bug that could bring back records
you had deleted, adds three things you can now do from your phone, and repairs
four features that had silently never run at all.

### Added

- **Photograph a receipt and file the expense on the spot.** A receipt is a
  photograph and your phone is the camera. The companion app now records an
  expense with the receipt attached — amount, category, a note, and a photo — and
  it lands in your expense list immediately, receipt and all. The picture is
  shrunk before sending, so it does not fill your disk or crawl over the shop
  Wi-Fi.

- **Log a failed print at the machine.** A print fails, and the moment to record
  it is while you are standing there holding it — not later, at the desk, if you
  remember. The companion app now logs waste in a few taps: pick the material
  from your own spools, say what went wrong, enter the grams, and optionally take
  those grams off the spool. It appears in your waste report immediately, and the
  desktop updates on the spot if it is open.

  The date is stamped by your desktop using your calendar day, so a failure
  logged just after midnight lands on the right day even if your phone is set to
  another timezone.

- **Quote a customer from your phone.** Someone walks in holding a part and asks
  what it would cost — the companion app now answers without you going back to
  the desktop. Enter the weight, print time and quantity, and it shows the price
  along with what the job actually costs you, broken down by material, machine,
  labour and failure buffer.

  The numbers come from your desktop, not the phone: it runs the same costing and
  the same margin, tier, discount and rush-fee rules the calculator tab uses, so
  a price you give standing next to a customer is the price on your desk. It
  needs a live connection for that reason — a quote you might have to honour
  should not be computed from yesterday's material prices.

### Changed

- **The LAN API no longer publishes every field on a spool.** `GET
  /api/inventory` returned the stored record as-is, so anything Khayt kept on a
  spool went out over the network — including your supplier and invoice
  reference — and any field added in a later version would have joined it
  automatically. It now returns the same fields the API accepts, plus the few the
  iOS companion needs. `supplier`, `invoice` and `costPerGram` are no longer
  included; if you read this endpoint from your own script and relied on one of
  them, that is the change to know about.

### Fixed

- **A budget warning could count the wrong month.** Khayt worked out the current
  month from UTC rather than from your own calendar, so for the first hours of
  the 1st (east of London) the overspend check was still totalling *last* month:
  log a 200 expense and be told you had blown a 5,000 budget. West of London it
  failed the other way on the last evening of a month, and stayed quiet when it
  should have warned. Same cause as the date fixes in 3.4.0-beta.5 — this one
  counted months rather than days, which is why it survived that sweep.

- **A record you deleted could come back.** If you deleted a client, order or
  spool while cloud sync had not yet caught up — you were offline, or another
  device pushed first — the next sync could re-add it and the next save kept it.
  This has been present since 3.3.0 and affects cloud sync only; shops with
  cloud off were never exposed. Khayt now refuses to re-add anything it knows
  you deleted.

  If it already happened to you, **Khayt will tell you**: on the next start it
  names the records that came back so you can delete them again. It does not
  delete them for you — you may have worked on one since it reappeared, and a
  second silent change is not a fix for the first.

- **A saved operator PIN using the older hashed format could never be
  accepted**, locking that operator out. **Spool labels were printed without
  sanitising the label HTML.** **QC-failure and RMA webhooks never fired**, and
  one webhook delivery path never delivered. All four were the same wiring
  mistake — a function that other files called was never made visible to them,
  so the call quietly did nothing. A new check covers the whole class.

## [3.4.0-beta.5] - 2026-07-28

A calendar beta. Khayt was working out what day it is from UTC rather than from
your own calendar — which is correct in London and wrong everywhere else for
part of every day. In Saudi Arabia that meant the first three hours after
midnight belonged to yesterday.

### Fixed

- **An expired quote could still be approved.** For the first three hours of
  every day in Saudi Arabia — and the last four in the Americas — Khayt worked
  out "today" from UTC rather than from your own calendar, so a quote that
  expired yesterday stayed approvable on the page your customer uses to accept
  it.
- **An order taken through the LAN page after midnight was dated yesterday.**
  Same cause, worse effect: that date is what the revenue-by-day reports group
  on, so the money landed on the wrong day. Orders arriving from Salla and Zid
  were dated the same way, and the kiosk count of work completed today covered
  the wrong hours.
- **A monthly recurring expense walked backwards a day every cycle** for any
  shop west of London. An expense anchored on the 15th became the 14th, then the
  13th, then the 12th. The date was being built on one calendar and read on
  another; now both are yours.
- The date printed inside a saved recovery-code file, and the date in a
  pre-update backup filename, were also UTC's rather than yours.

## [3.4.0-beta.4] - 2026-07-27

An eighth design, and the end of a class of bug where a control was on screen
but out of reach. Khayt goes from seven designs to eight — Flow, the first one
where you run the shop by dragging work rather than reading about it.

### Added

- **Flow — an eighth design, and the first where the board is the home screen.**
  Khayt has always had a kanban board, but it lived on a tab you visited, which
  made it a report: you went and looked at it. In Flow the board IS the home
  screen, and moving a card is how you run the shop — open the app and your
  hands are already on the work. Columns show what is where, a column past its
  WIP limit turns red before you drop anything into it, and the strip above
  gives you the count in flight, what is late and what is owed. Dragging a job
  goes through exactly the same checks as moving it anywhere else in Khayt, so
  an assembly with parts still in QC refuses to complete here too.

### Fixed

- **Command and Nocturne lost the language picker on a narrow window.** Below
  about 1100px the top-bar controls kept their full width instead of giving way,
  pushing the last one clean off the right edge — and since the app has no
  sideways scrolling, off the edge meant gone. The row now gives way and scrolls
  if it has to, so nothing is stranded.

## [3.4.0-beta.3] - 2026-07-27

The beta that stops the app speaking English at people who did not choose it.
Dates followed your computer's language rather than Khayt's, a whole Bed Ready
feature had never been translated, and an update that was downloading perfectly
well looked like it had frozen. Meridian also could not be scrolled.

### Fixed

- **Meridian could not be scrolled.** On any screen with more content than fits
  the window — the inventory list, most obviously — everything below the fold
  was unreachable. No scrollbar, no overflow, no way down. The page itself never
  scrolls in Khayt by design, so each design has to nominate an inner area that
  does; Meridian nominated none, and let its layout grow past the window instead
  of filling it. Every design is now checked, by shrinking the window until the
  content must overflow and confirming it actually scrolls.

- **A whole Bed Ready feature had never been translated.** The filament-care log
  asked for 30 locale keys that no language file defined. Because the code
  supplies an English fallback for each, every screen looked finished — in
  English — in all nine languages, and nothing reported a problem. Those keys
  now exist, translated.
- **Tooltips, placeholders and several labels were English everywhere.** The
  theme toggle, notification bell, location filter, global search, the G-code
  parser and quote buttons, the waste search box, the aged-receivables report
  and the NPS panel all carried text no translation could reach. The theme
  toggle and bell alone appear on every screen in the app.
- **A guard now fails the build on a key the code asks for but no language
  defines** — the mirror of the existing one that fails on a key nothing uses.
  Together they close the loop in both directions. Fixing a hole in the latter
  also mattered: one dynamic `.title` lookup had been making every key whose
  name ends in _title look used, so a dead one could never have been reported.

- **Dates and times ignored the language you chose.** Of 51 places Khayt formats
  a date or a time, 49 were wrong. Thirteen asked "is this Arabic?" and fell
  back to American English for everything else — so German, Spanish, French,
  Japanese, Turkish, Chinese and Brazilian Portuguese all got US dates. Six were
  hardcoded to English outright. Thirty passed no language at all, which means
  they followed the computer's setting rather than Khayt's: choosing 日本語 still
  produced "Monday, July 27, 2026" on an English Mac. Every one of them now
  follows the language you picked. Arabic keeps Western digits — the same
  deliberate choice the rest of the app makes — while its month and day names
  are Arabic, and the Hijri calendar is untouched.
- **Two calendars were permanently English.** The analytics activity heatmap and
  the calendar view both carried a hardcoded `Sun, Mon, Tue…` list, invisible in
  English and unchangeable in every other language. The same bug the email
  digest had. Both now come from the system's own calendar data.
- **The Meridian header kept the old language for half a minute** after
  switching, because its date only repainted on a 30-second timer.

- **A working update download looked like a frozen one.** The update is over
  150 MB. The progress panel showed a bar and a bare percentage — which on a
  file that size creeps a single point every few seconds — and nothing else, so
  a download running perfectly well was indistinguishable from one that had
  died. Reported from the field as "it found the beta and started the download
  but nothing is downloading"; the download was fine and finished on its own.
  The panel now shows how much has arrived, the current speed and a rough time
  remaining, all of which the app was already receiving and throwing away.
- **A download that really has stalled now says so.** After 45 seconds with no
  progress the panel says the download has stopped moving and points to the
  manual download, instead of showing a bar that will never fill. It does not
  cancel anything — if the download recovers, the message clears itself.
- **Screen readers announced 0% for the entire download.** The progress bar
  never updated its accessible value, and the whole live region was rebuilt on
  every progress tick, which made it re-announce several times a second.
- **Update failures left no trace.** electron-updater was running without a
  logger, so a stalled or failed update produced no record of the feed it used,
  the file it chose, or how far it got. It now logs to the app's standard error.

## [3.4.0-beta.2] - 2026-07-27

A translation beta. The email digest and four settings sections were showing
English to everyone regardless of language; both are fixed, and a new guard
means a rewrite can no longer silently orphan its translations.

### Fixed

- **The email digest settings were part English in every language.** "Daily" and
  "Weekly" — and all seven day-of-week names — were written into the markup as
  plain English, so choosing Arabic gave you `يومي` nowhere and "Sunday, Monday"
  in an otherwise right-to-left panel. Japanese showed "Daily, Weekly, 毎月":
  two English words next to a translated one. The frequency labels now use the
  translations that already existed in all nine languages, and the weekday names
  come from the system's own calendar data, so they are correct in every
  language — including ones Khayt does not ship a translation for. Stored
  settings are unaffected: only the labels changed, not the values behind them.
- **Four settings sections and two of their descriptions never translated.**
  "LAN API & iCal", "Fixed Costs & Break-Even", "Outbound Webhooks" and
  "Salla / Zid Webhooks" shipped without translation markers, so they stayed in
  English no matter the language. Now translated into all nine.

### Removed

- **205 locale strings that no code could reach**, across all nine languages —
  roughly 1,850 translated lines. These accumulated when features were rewritten
  and their old strings left behind; every one of them was re-read and
  re-reviewed on each translation pass for UI that could never display it. A new
  test now fails if an unreachable string is added, which is how the email
  digest bug above surfaced: its real translations had been orphaned by a
  rewrite while the screen quietly fell back to English.
- Three one-shot migration scripts (`apply-studio-4-1.py`, `patch-phase3.py`,
  `patch-phase4.py`) that patched markup which no longer exists — they were
  no-ops, and their snapshots of old code made dead strings look alive.

## [3.4.0-beta.1] - 2026-07-27

Opens the 3.4 beta line. Khayt goes from three designs to seven — two of them
new ways of working rather than new colours — and gains a ninth language.

### Added

- **Four new looks, and two of them are new ways to work — not just new colours.**
  Khayt had three designs; it now has seven.
  - **Blueprint** — warm paper and blueprint blue, the drafting-room calm of Bed
    Ready's look, with a deep blue dark mode.
  - **Nocturne** — dark by default with amber instrument accents. Built for
    checking a farm at 2am: amber keeps your eyes adjusted to the dark the way
    an instrument panel does, and colour is saved for warnings so a real problem
    is the loudest thing on the screen.
  - **Meridian** — a schedule instead of a dashboard. Your printers are lanes on
    a clock, jobs are blocks sized by how long they take, and a line marks now,
    so you can see what is running, where the gaps are, and what will be late.
    **Drag a job onto another printer to reassign it.** There is no sidebar —
    the time axis needs the room.
  - **Foreman** — a list you empty rather than a dashboard you read. Everything
    needing a decision, worst first, with a count that follows you onto every
    screen and reaches zero when you are done. J and K move, Enter opens.

- **Português (Brasil).** A complete translation — all 3,675 phrases, not a
  partial one — bringing Khayt to nine languages.

### Fixed

- **Faint text was too faint to read in every light theme.** Hints, subtitles
  and the small print under figures failed the accessibility contrast standard
  in ten of fourteen theme and light/dark combinations — worst in Command, at
  little over half the required contrast. Every one now passes, with the
  colours otherwise unchanged.

- **"Coming soon" themes both introduced themselves as Workbench.** The two
  preview cards in Settings showed Workbench's name and description instead of
  their own. They have always done this; it only became obvious once there were
  more themes beside them.

- **A stray "— —" under the content on every screen.** Left over from a design
  removed several releases ago, in all seven themes.

- **Meridian's top bar now shows it can scroll**, with arrows when there are
  more tabs than fit, and always keeps the screen you are on in view.

## [3.3.0] - 2026-07-26

The 3.3.0 beta line, released as stable. Individual beta entries are kept below;
this is what changed for you since 3.2.0.

The headline is the numbers. A sweep over everything the app reports found six
places where it was telling you something untrue about your own shop — and
because none of them crashed anything, none of them were obvious. Where a bug
had already damaged saved data, this release finds the damage and offers to
undo it rather than leaving you to reconcile by hand.

### Fixed — first run, and security

- **The setup wizard could not get past "Choose your look".** On a new install the
  theme step showed no themes and the Continue button did nothing, and pressing
  Escape to skip did not work either — so a new shop could not finish setting up
  at all. All of it works now, and the theme you pick is remembered.

- **Security: the updater could leak its credentials when a download redirected.**
  Khayt's update component had a flaw where an authorization header could be
  passed on to a different server if the download was redirected. Updated to the
  fixed version, along with every other known vulnerability in the parts Khayt
  ships — there are now none outstanding.

- **A setting in Bed Ready showed a piece of internal code instead of its
  description.** The theme hint read "theme.design.studio_desc" rather than
  describing the theme. Now translated in all eight languages.

### Fixed — what the app told you about your money

- **Cancelled invoices were still counted as revenue.** Voiding an invoice
  deliberately keeps the order marked completed, so twelve different figures —
  the quarterly P&L, the headline revenue tile, product profitability, the
  location P&L and the P&L export among them — went on counting money you had
  cancelled, and the VAT collected alongside it.

- **Refunds never reduced revenue.** A credit note against a completed order
  left the reported figure untouched: a 3,000 job refunded 1,200 still showed
  3,000, with VAT to match.

- **An automatic reorder could be priced about a thousand times too high.** A
  purchase order for 750 g of an 85/kg spool asked for 63,750 instead of 63.75.

- **Saving an order with a payment plan could wipe its deposit.** The recorded
  deposit was replaced by the instalment total, so an order with 500 already
  paid dropped to zero and its outstanding balance rose by the same amount,
  with nothing on screen to say so.

- **An order could report itself fully paid on a partial plan.** "Paid" was
  decided against the instalment rows rather than the agreed price, so two 100
  instalments on a 2,000 order settled the whole thing.

- **A month's profit margin averaged percentages instead of blending money.**
  One small high-margin job could outweigh a large low-margin one — a month
  that really ran at 10.7% could show 45%, coloured green.

- **Archived orders held on to their stock.** Filament stayed reserved against
  jobs nobody was going to print, so spools looked more committed than they
  were and over-commitment warnings fired against work that no longer existed.

### Fixed — dates

- **"Today" was the wrong day for part of every day.** Dates were computed in
  UTC rather than your own timezone, so before 03:00 in Riyadh the app used
  yesterday, and after 20:00 in New York it used tomorrow. In practice: the
  payments-due card ran a six-day window instead of seven, and "last quarter"
  both dropped the final day of the quarter and pulled in a day from the one
  before. Fixed across the whole app.

### Added — putting damaged data right

- **Deposits erased by the payment-plan bug can be restored.** They turned out
  to be recoverable: the original figure was still on file. A notice above your
  orders names each affected order, shows what it will become, and totals the
  cash currently unaccounted for. Nothing changes until you say so, and every
  restore can be undone.

- **Purchase orders left wrong by the reorder pricing bug are found for you.**
  A banner names each one with both figures and offers a one-click, undoable
  correction. It never corrects on its own — an order may already have gone to
  a supplier — and only draft and ordered ones are offered a fix.

### Added — printers

- **Pause, resume and cancel a running print from Khayt.** Works with
  Klipper/Moonraker, OctoPrint, PrusaLink and Duet. Bambu still requires their
  own app, and Khayt now says so instead of failing quietly.

### Changed — the AI features

- **Each AI feature is now switched on separately, and says what it sends.**
  One checkbox used to govern four features that transmit very different
  things. Every feature now lists exactly what leaves your device, and the one
  that sends a customer's name is marked and starts switched off until you turn
  it on having read that.

- **The privacy screen no longer overstates itself.** It said customer data
  stays on your machine; with reply drafting enabled that was not true. It now
  says so, in place, only when it applies.

- **You can see what the AI costs you, per feature.** It runs on your own key,
  so the bill is yours — but the provider's console shows one total and only
  Khayt knows which feature spent it. Counts this device only, and says so.

### Fixed — interface

- **Urgent states were quieter than calm ones.** Overdue and unassigned markers
  were being drawn with colours that did not exist in most themes, so they
  rendered with no fill at all while ordinary rows kept theirs.

- **A customer's colour could erase an order's urgency.** The red stripe on an
  urgent card was overwritten whenever that customer had a colour set.

- **Things that looked clickable now are.** Rows in the queue and on the
  dashboard highlighted on hover but did nothing; they open the order now.
  "Finished today" could not be expanded. The status bar claimed "synced" from
  a fixed label that never checked whether syncing had worked — it reads the
  real state, and says nothing when sync is off rather than reassuring you.

## [3.3.0-beta.1] - 2026-07-25

Opens the 3.3 beta line, after v3.2.0 shipped stable on 2026-07-22. The
headline is a sweep over the numbers the app reports: refunds, cancelled
invoices and a reorder pricing bug were all quietly inflating what the app told
you about your own shop.

### Added

- **Pause, resume and cancel a running print from Khayt.** Previously you could send a job to a printer and watch it, but had to walk over to the machine to stop it. Works with Klipper/Moonraker, OctoPrint, PrusaLink and Duet; Bambu still needs their own app, and Khayt now says so instead of failing silently.

- **You can now see what the AI features cost you, broken down by feature.** The assistant runs on your own Anthropic key, so the bill is yours — but the console shows a single total and only Khayt knows which feature spent it. There is now a per-month, per-feature ledger, so "is the assistant worth leaving on?" is a decision you can actually make. The figure counts this device only and says so on screen.

- **Purchase orders left over from the reorder pricing bug are now found for you.** A banner above the purchase-order list names each affected order with both the wrong and the correct figure, and offers a one-click, undoable correction. It never corrects on its own: an order may already have gone to a supplier, and only draft and ordered ones are offered a fix — received and cancelled orders are history and are left alone.

### Changed

- **Seven themes became three.** Four of them could not be picked at all, yet every one of them still had to be maintained — six separate dashboards among them. What is left is Workbench, Command and Vivid, each properly finished.

- **The dashboard leads with what actually needs you.** Everything on it previously shouted at the same volume, so nothing stood out. Interruptions and the state of your fleet now sit above the fold, and the rest is quieter.

- **The queue tells you what is wrong without a hunt.** Finding a problem meant sweeping seven columns; the queue now surfaces it directly. Rows also open the order behind them by mouse or keyboard.

- **Less chrome before the work.** Four rows of toolbars and headers sat above anything useful; that is now trimmed so the screen opens on your jobs.

- **Bed Ready looks like itself.** It had been borrowing a Khayt theme to stand in for its own identity.

### Fixed

- **A refund never left the revenue it repaid.** An order priced 3,000 with a 1,200 credit note against it still reported the full 3,000 as revenue, and charged VAT on all of it — overstating profit by the refunded amount. Refunds are now netted out of every revenue, profit, margin and VAT figure in the app, including the quarterly P&L, the tax summary and the standard-rated sales box of the VAT return. Nothing needs re-entering; the figures recalculate on their own.

- **Six figures the app reported wrongly.** An auto-drafted reorder could be priced about a thousand times too high; cancelled invoices were still counted as revenue in twelve places; saving an order with an instalment plan could wipe a recorded deposit; an order could report itself fully paid on a partial plan; archived orders held on to their stock reservations; and a month's margin averaged percentages instead of blending the money, so one tiny job could dominate it.

- **The cloud server address is now checked before your password is sent to it.** A plain `http://` address on the internet would have sent your email and password unencrypted; Khayt now requires `https://` there, while still allowing `http://` for a server you run yourself on your own machine or network.

- **The privacy screen promised customer data never left the machine.** It said more than the app could stand behind. The wording now matches what actually happens.

- **Crash reports were sent even when you had not turned them on.** Settings offers crash reporting as an opt-in and says Khayt sends nothing by default, but the reporter ignored that setting in installed builds and sent error details anyway. It now honours the setting, and stays off unless you switch it on.

- **The status bar claimed "synced" no matter what.** The tick and the green dot were fixed in place and read nothing, so it reported healthy while sync was failing, offline, locked, or switched off — the one thing you would check before closing the laptop. It now reflects the real state.

- **A synced delete could erase an edit with no trace.** Nothing recorded that it had happened.

- **Groundwork for multi-device sync: two devices editing the same record no longer end up disagreeing.** Previously each kept its own copy and neither was told. One edit is still replaced, but every device now reaches the same result instead of quietly drifting apart.

- **"Today" was yesterday in Riyadh and tomorrow in New York.** Dates were bucketed against UTC rather than your own day, so figures landed in the wrong day either side of midnight.

- **Khayt could hang at startup.** A dialog on the path that loads your store could stop the app before it finished opening. A second issue could also let a redundant save race the app shutting down.

- **Three of four AI features told the model they were quoting.** Each now describes the job it is actually doing, so the replies suit the task.

- **Rows that looked clickable now are.** The queue list and the dashboard job rows painted a hover highlight but had nothing wired to them. Both now open the order behind them, by mouse or keyboard, with a visible focus ring.

- **Urgent pills and some labels rendered with no colour, and a few showed raw names.** Colours and text used by shared screens were defined only in the Bed Ready stylesheets, so in Khayt's own themes they fell back to nothing.

- **The three themes disagreed about what "offline" meant.** Each decided it privately, and a single missed poll was enough to call a healthy printer offline. They now share one definition, with tolerance for a missed reading.

- **Klipper printers rejected Khayt when they required a key.** Khayt never sent its API key to Klipper/Moonraker printers, so any printer set to require a login refused every request with no explanation. Machines saved without a key also sent an invalid one instead of none.

- **A Duet printer could report a wildly wrong progress percentage.** Before the job file was fully read, progress was calculated against a missing file size and could show a number in the millions. Progress from every printer type is now kept within 0-100%.

- **Smaller fixes.** The queue toolbar drew its icons in the operating system's emoji font instead of Khayt's own, and the top-bar search box lost its layout in Bed Ready.

## [3.2.0] - 2026-07-22

The 3.2.0 beta line, released as stable. Individual beta entries are kept below;
this is what changed for you since 3.1.0.

### Fixed — pricing and your data

- **Quoted prices ignored how many of each part you were making.** Multi-part orders
  were costed as though you were printing one of everything, so quotes could come out
  far below what the job actually cost you.
- **Reported profit margins were higher than the real ones**, for the same reason.
- **Saving in two places at once could damage your saved data.** Writes now can't
  overwrite each other.
- **Saving settings could wipe stored passwords and keys** for email, cloud sync and
  accounting.

### Fixed — things that quietly never ran

- **Printer alerts never fired.** The module that watches for a stopped or failed print
  wasn't being loaded at all.
- **The scheduled daily summary email was never sent.**
- **Ctrl/⌘+K never opened search.**
- **A printer added after startup stayed dark until you restarted Khayt.**

### Fixed — Arabic and other languages

- **Names were shortened from the wrong end**, hiding the part you actually read.
- **Dates and numbers used Eastern Arabic numerals** where Saudi apps use Western ones.
- Short English names sat on the wrong side of their column.

### Fixed — printing and colour

- **A brief network drop made a working printer look offline**, and blanked out the job
  it was running.
- Full Spectrum produced wrong colours beyond 18 filament slots.
- A filament change was inserted at the first layer, wasting a change for nothing.
- The bed outline was corrupted on four-filament models.
- **The Analytics screen failed to load once a shop had real data.**

### Added

- Assembly tracking for multi-part orders, with per-part status and reprints.
- Scoped API tokens for the local API.
- Per-printer camera feed (LAN only).
- Printer discovery on the local network, including PrusaLink and Moonraker.
- Keyboard shortcuts shown on the sidebar items they belong to.


## [3.2.0-beta.61] - 2026-07-22

### Added

- **Keyboard shortcuts now show on the sidebar items they belong to.** The letter that jumps to each screen sits quietly on that screen's nav item, so you pick it up while working normally instead of having to find the shortcuts list.

## [3.2.0-beta.60] - 2026-07-22

### Fixed

- **The totals under the "waiting to start" column were squashed and ran past the column edge.** The assign button in that column's heading left no room for the hours and value beneath it, so they wrapped onto two cramped lines. Most visible in Arabic, where the labels are longer.

## [3.2.0-beta.59] - 2026-07-22

### Fixed

- **Arabic showed Eastern Arabic numerals where Saudi apps use Western ones.** Dates and times in the Arabic interface rendered as ٢٢ يوليو ٢٠٢٦ rather than 22 يوليو 2026. Large numbers — revenue, profit, stock weight — also followed the computer's regional settings rather than Khayt's, so an English interface on a machine set to Saudi Arabia showed Arabic digits.

## [3.2.0-beta.58] - 2026-07-22

### Fixed

- **In Arabic, short English names sat on the wrong side of the column.** A follow-on from the truncation fix in beta.56: names that were short enough to fit jumped to the left while Arabic names stayed right, leaving the column edge ragged.

## [3.2.0-beta.57] - 2026-07-22

### Fixed

- **A printer briefly dropping off the network was shown as offline.** One missed check was enough to turn a working printer red and blank out the job it was running — common on Wi-Fi, and normal for a Prusa CORE One, which takes 20–30 seconds to answer after a power cycle. The dashboard now keeps showing the last known job and reports "Reconnecting", and only marks a printer offline once it has genuinely stopped answering.

## [3.2.0-beta.56] - 2026-07-22

### Fixed

- **In Arabic, names were shortened from the wrong end.** A job called "Gearbox housing batch" appeared as "…ousing batch" instead of "Gearbox hous…", hiding the part of the name you actually read. The same fault affected machine names, client names and file paths anywhere they were too long to fit.

## [3.2.0-beta.55] - 2026-07-21

### Fixed

- **The Analytics screen failed to load once you had printers and completed orders.** A fault introduced in beta.40 broke the printer-utilisation chart, and because it only triggered on real data it was invisible on a new or empty account.

## [3.2.0-beta.54] - 2026-07-21

### Fixed

- **A printer added after Khayt was already running never went live until you restarted the app.** Live status was only ever started once, at launch, using the printers that existed at that moment — so a machine you just added with "Scan network" stayed blank no matter how long you waited. It now connects the moment you save it.

## [3.2.0-beta.53] - 2026-07-21

### Fixed

- **A malformed 3MF whose parts reference each other in a loop no longer produces a broken preview.** Khayt now stops following the loop instead of reporting far more geometry than it actually loaded.

## [3.2.0-beta.52] - 2026-07-21

### Fixed

- **Full Spectrum could print the wrong colours on large palettes.** Above about eighteen colours the file format cannot record the extra slots, and Khayt silently substituted a different filament instead. It now declines those palettes and falls back to a plain conversion rather than producing a wrong print.

## [3.2.0-beta.51] - 2026-07-21

### Fixed

- **Band-swap prints could pause at the very first layer for no reason**, asking you to load filament that was already on the head. This happened whenever the first colour printed wasn't the lowest-numbered one.
- **A Bambu printer check could hang for eight seconds and then report the wrong reason.** A malformed reply from the network crashed the reader internally and surfaced as "check IP, access code & LAN mode" instead of a protocol error.

## [3.2.0-beta.50] - 2026-07-21

### Fixed

- **Converting a four-colour model could corrupt the printer's bed outline.** When reordering filaments for band swapping or Full Spectrum, Khayt also reshuffled any other setting that happened to have four values — including the bed's four corners, which turned the print area into a crossed shape. Only filament settings are reordered now.

## [3.2.0-beta.49] - 2026-07-21

### Fixed

- **The converter contradicted itself about filament swaps.** It could announce "2 filament swaps" directly above a line saying no manual swap was needed. The count was based on how many colour bands the model had rather than how many distinct colours — a model alternating between two colours up its height needs no swaps at all on a four-head printer, and needs one at every change on a single-extruder machine. The figure now matches the swap plan exactly.

## [3.2.0-beta.48] - 2026-07-21

### Fixed

- **Some 3MF files previewed as empty or converted with the wrong colours.** The preview read only one of the several ways a 3MF may legally be written, so a file from another slicer could show nothing — or convert incorrectly with no warning — while the converter read it fine. Both now read files identically.
- **A model could disappear entirely** depending on the order of attributes in the file.

### Changed

- Two source files contained a raw control character that made search tools treat them as binary and skip them silently. Written differently now, with no change in behaviour.

## [3.2.0-beta.47] - 2026-07-21

### Fixed

- **Printer alerts never fired for anyone who set up Telegram before this feature existed.** The settings screen showed the alert boxes ticked while the alerts were actually switched off. Turning them off explicitly still works as expected.
- **Revenue forecasting put some sales in the wrong month.** Orders completed between midnight and 3am were credited to the previous month, and opening Khayt in those hours shifted the whole forecast window back a month.

## [3.2.0-beta.46] - 2026-07-21

### Security

- **Outbound address blocking did not work for IPv6.** Khayt refuses to send webhooks and other outbound requests to your own machine or private network, but the check only ever worked for ordinary IPv4 addresses — the IPv6 equivalents passed straight through. Anyone able to set a webhook or accounting URL in your settings (including via a restored or synced backup) could have used it to reach services running on your computer. Now blocked in every form.

### Fixed

- **The remote-access PIN could be guessed without limit.** The lockout on read requests could be sidestepped by a caller changing one header, and repeated attempts also grew memory without bound — a way to slow or crash the app from outside. Read requests now use the same global lockout the write side already had, and stale lockout records are cleaned up.
- Deleting a restore point reported success even when the file could not be removed.

## [3.2.0-beta.45] - 2026-07-21

### Changed

- Added internal checks that catch a whole class of wiring fault before release — the kind that made printer alerts and the scheduled digest email silently never run. No change to how the app behaves.

## [3.2.0-beta.44] - 2026-07-21

### Fixed

- **Quitting while Khayt was still starting up could skip the final save.** The shutdown now allows more time for the save to finish, and still never prevents the app from closing.

## [3.2.0-beta.43] - 2026-07-21

### Fixed

- **Adding a fee to a quote made the margin go down.** Extra charges were counted as both income and cost, so a 100 fee on a 30%-margin job showed 17.6% instead of 58.8%.
- **Deleting from the print library said "File deleted" even when the file could not be removed** — it disappeared from the library while staying on disk.

## [3.2.0-beta.42] - 2026-07-21

### Fixed

- **The live price shown while filling in a part didn't match what landed in the cart.** Packaging wasn't spread across the quantity in the preview, so a 20-unit part could preview at 17.00 and be added at 7.50. Resin parts could also change price on being added.
- **Editing a part in the cart silently discarded eight of its details** — including support weight, which changed the price. Colour, note, layer height, infill, profile, attached file and spool were all lost too.
- **An attached model file carried over to the next part you added**, so the second item in an order referenced the first item's file.

## [3.2.0-beta.41] - 2026-07-21

### Fixed

- **Printer alert notifications never worked** — the feature was never loaded into the app at all.
- **The accounting journal export labelled foreign-currency invoices with your home currency**, left credit notes out entirely (so a credited invoice stayed booked as revenue), and repeated the VAT figure on two rows so the column double-counted.
- **Customer statements didn't add up** when a gift card or credit note was involved — charges minus payments didn't match the balance shown, with no line explaining the difference. Both now appear as their own settlement figures.
- **The acquisition-sources chart understated every channel.** Orders from the online intake form counted toward the total but never appeared as a bar, so the percentages didn't sum to 100%.

## [3.2.0-beta.40] - 2026-07-21

### Fixed

- **Adding a product from the catalogue to a quote undercharged by the quantity.** A 50-unit line was priced as one unit while all 50 still printed. This is the same fault fixed for duplicated and reprinted orders in beta.30 — the catalogue path was a third place it occurred.
- **The scheduled digest email never sent.** It failed silently every five minutes and looked like a mail-server problem.
- **Failed accounting pushes were still never retried on restart** — the retry added in beta.33 could not actually run.
- **Machine profit charged a whole year of maintenance against any period.** Picking "This month" subtracted January's servicing from July's revenue, which could make a profitable printer look like a loss.
- **Machine utilisation was wrong on "All time" and custom ranges** — it always divided by 30 days, so three years of printing showed as 100% busy.
- **Quarterly profit only charged rent and overheads to the current quarter**, so every past quarter looked more profitable than it was.
- The new printer's colour palette, the calendar's "back to this month" reset, the dashboard's copy-intake-link button, and form labelling at startup were all silently inert.

## [3.2.0-beta.39] - 2026-07-21

### Fixed

- **Tax invoices could be a penny out of balance at VAT rates other than 15%.** The tax-exclusive and tax amounts were each rounded separately, so they did not always add up to the total — which makes the invoice XML invalid. Saudi invoices at 15% were never affected; shops using other rates were, on about one total in eight at 20%.
- **Calendar chips now say which machine and status they represent** instead of relying on colour alone.

## [3.2.0-beta.38] - 2026-07-21

### Fixed

- **The ⌘K / Ctrl+K search shortcut never opened search.** It raised an internal error instead — as did every other keypress in the app. Both are fixed; the shortcut now works.
- **The low-stock alerts panel can be expanded with the keyboard**, so the "Draft PO" buttons inside it are reachable.
- Price-list and address tables in the customer window now scroll on a narrow window instead of being cut off.

## [3.2.0-beta.37] - 2026-07-21

### Fixed

- **Order webhooks are no longer lost on a temporary network blip.** Order events (paid, shipped) feeding your automations were sent once with no retry, while other webhooks already had durable retry. They now use the same queue: retries with backoff, resumed after a restart, and a warning if delivery finally fails.
- **The event-webhook signing secret is now stored encrypted** and hidden from the app window, matching every other credential. It was already hidden from backups, but not at rest.
- **Calendar days, the add-photo tile and the copy-webhook-URL control can be used with the keyboard.**
- Order photos are now described to screen readers instead of being skipped.

## [3.2.0-beta.36] - 2026-07-21

### Fixed

- **"No backups found" no longer appears when the backups folder simply couldn't be read.** That message showed up exactly when someone was trying to recover, and could convince them their data was gone when it wasn't.
- **A camera that errors now shows "Camera offline"** instead of leaving the tile stuck on "Camera…" indefinitely.
- **Customers submitting a request are no longer told their form was invalid when the shop's computer failed to save it.** They were being asked to correct a form that was already correct.
- Starting the LAN server from the Online panel now reports failure instead of leaving the panel unchanged.

## [3.2.0-beta.35] - 2026-07-21

### Fixed

- **Resin wash, cure and "complete post-processing" can now be used with the keyboard** — they were plain blocks that only responded to a mouse, despite the label saying "tap to log".
- **Per-part status can be changed with the keyboard**, and now announces which part and what state.
- **Every button in the app has a proper name.** Icon-only controls such as the feedback button previously announced as the emoji itself.
- **Currency rates, operator PINs and storefront product rows are now identified individually.** Previously every row in those lists was announced identically, with no way to tell which currency, operator or product it belonged to.
- **Printer status changes are announced** — a print entering an error state was previously silent.

## [3.2.0-beta.34] - 2026-07-21

### Fixed

- **Opening your data with an older Khayt could delete part of it.** Data files now record which version wrote them, and an older build refuses to save over a newer file instead of quietly dropping whatever it doesn't recognise.
- **Payment plans created late at night were immediately overdue.** Between midnight and 3am local time the deposit and first instalment were dated the previous day. Dates now follow your own timezone.
- **Reserved filament ignored support material**, so the queued-grams figure under-reserved stock on support-heavy jobs.
- **Labels and packing slips printed left-to-right even in Arabic.** They now follow the app's language.
- Coloured accent stripes on cards now sit on the correct side in Arabic.

## [3.2.0-beta.33] - 2026-07-20

### Fixed

- **Attaching a customer's model file could report success without attaching anything.** Files on a NAS, an external drive or a USB stick were rejected for security reasons, but the confirmation appeared anyway. The real reason is now shown.
- **Deleting a file said "deleted" even when it wasn't.** A file locked by another program stayed on disk while disappearing from the list — which matters, because customers are told their files can be deleted on request.
- **Invoice emails reported success when sending had failed.** An expired mail-provider key silently fell back to opening your mail app — with no invoice attached — and still said "sent". The real error is now shown, and the fallback no longer claims the email went out.
- **Invoices could quietly never reach your accounting system.** If the connection failed at the moment an order was marked paid, nothing was reported and it was never retried. Failures are now shown and retried the next time Khayt starts.
- **Printer tiles could show stale information as if it were live** — a finished printer could keep reading "Printing 47%" indefinitely if updates stopped. Tiles now say how long it has been since the last update.
- **Batch invoice export claimed every invoice succeeded.** If one failed you were told all of them exported. It now reports how many succeeded and which failed.
- A failed photo save no longer leaves an order pointing at a photo that does not exist.

## [3.2.0-beta.32] - 2026-07-20

### Fixed

- **Arabic text no longer has its letters prised apart.** Arabic is a connected script, but ~55 letter-spacing rules applied to it and none were ever cancelled — headings, figures and menu labels all rendered with broken letterforms.
- **Latin names and codes now read correctly in the Arabic interface.** A printer saved as "Prusa CORE One+" displayed as "+Prusa CORE One". Text fields now take their direction from their own content, so models, emails, IBANs and IDs read properly either way.
- **Arrows point the right way in Arabic.** The calendar's previous/next arrows and the sidebar and column collapse arrows kept pointing left after the layout mirrored, contradicting where they had moved to.
- **The filament catalogue can be used without a mouse.** Its cards were plain blocks, so a keyboard user could search the catalogue but not choose anything.
- **Machine colours can be picked with the keyboard**, and the selected one is now announced.
- **Cards can be reordered in every column, by keyboard.** The up/down buttons existed only in "Pending" — and their handler ignored every other column even when they were shown.
- Around 30 icon-only buttons across the app announced as their symbol's name ("multiplication sign", "clipboard") instead of what they do. They now carry proper labels, translated.

## [3.2.0-beta.31] - 2026-07-20

### Fixed

- **Your whole database could be destroyed by two saves happening at once.** If a phone or tablet used the LAN features while the app was saving, both writes went through the same temporary file and could shred each other — leaving no usable data file and a corrupted backup. Khayt then read that as a brand-new installation and showed the setup wizard, and the next save overwrote the last surviving copy. Saves are now queued and each uses its own temporary file, and a surviving backup is never mistaken for a fresh install.
- **Five saved credentials were wiped the first time settings were saved.** SMS/WhatsApp, accounting sync, the AI key and the **Khayt Cloud token** were blanked out on a normal save — so off-site backup silently stopped working. Credentials are now protected by construction rather than by a hand-kept list.
- **Restoring a backup or importing a file wiped everything *before* checking the file.** Choosing the wrong file emptied the app and reported "restored successfully". Khayt now validates first and leaves your data untouched if the file cannot be read.
- **Work done in the last moment before quitting is no longer lost.** Khayt now finishes saving before it exits.

## [3.2.0-beta.30] - 2026-07-20

### Fixed

- **Duplicating or reprinting an order quoted it far too cheaply.** The rebuilt cart priced the job as a *single unit* while still printing — and deducting filament for — the full quantity. A repeat of a 100-unit order was quoted at about 1% of its true cost. Re-quote any order you duplicated or reprinted.
- **Profit, margin and the P&L export were wildly overstated on multi-unit orders.** Cost of goods counted one unit per line against the whole order's revenue, so a job with a real 28% margin reported 99%. This affected the analytics dashboards, per-machine and per-product profitability, the KPI rows and the exported P&L CSV. Figures correct themselves once this update is installed; previously exported P&L files should be re-exported.
- **Save failures were completely silent.** If a save could not be written — disk full, permissions, or a store too large — Khayt showed no warning and the work was lost at next launch. Failures now surface with the reason.
- **Dragging a card to reorder it only worked in the "Pending" column.** In the other five columns the new order was written to disk and then visually reverted on the next refresh.

## [3.2.0-beta.29] - 2026-07-20

### Added

- **The Snapmaker U1 works now.** It runs Klipper and serves a standard Moonraker API, so Khayt's existing Moonraker support drives it — live status, job name, progress and temperatures. Discovery sets it up automatically. The previous release said Khayt could not connect to it; that was wrong.

### Fixed

- **Printer cameras behind a login could never load.** The snapshot fetch sent no credentials, so a PrusaLink camera returned "unauthorized" every time. It now uses the same key already saved for that printer.
- **Removed an incorrect warning** telling owners to switch a cloud-linked printer to LAN mode for local status. Local status works either way.
- Discovery no longer assumes the port a printer advertises is the port its API listens on — the U1 announces one port and serves its API on another.

## [3.2.0-beta.28] - 2026-07-20

### Added

- **Find printers on your network instead of typing IP addresses.** The machine dialog has a **Scan network** button: printers that announce themselves are listed with their model, and picking one fills in the build volume, nozzle, colour slots and power draw from the built-in catalog, plus the connection type and address. Verified against a Prusa CORE One and a Snapmaker U1.
- **PrusaLink webcam support.** Camera URLs are now derived for PrusaLink printers, not just OctoPrint and Moonraker.

### Changed

- The PrusaLink connection option now names the **CORE One** alongside MK4 / XL / Mini+, so Core One owners can tell it applies to them.

### Notes

- Discovery reports honestly when Khayt cannot yet drive a printer it found: the Snapmaker U1 is identified and its specs filled in, but it is listed as not connectable rather than offered a connection that would never report status. A printer in vendor-cloud mode is flagged, since its local interface stays silent until switched to LAN mode.

## [3.2.0-beta.27] - 2026-07-20

### Changed

- **Backup exports now mask credentials for any shipping carrier or BNPL provider, including ones added in future versions.** Redaction previously named the three carriers and three providers explicitly, so a carrier added later would have had its API key and webhook secret written into an unredacted export. No shipped version was affected — the lists happened to match — but the guarantee no longer depends on the two being kept in sync by hand.

## [3.2.0-beta.26] - 2026-07-20

### Fixed

- **Crash reports could carry a credential or a customer's name.** Crash telemetry is opt-in and scrubs paths and personal data, but it only masked secrets stored under a recognised *field name* — a credential quoted inside an error *message* (a printer API key in a request URL, an auth header, a ZATCA certificate password, the LAN PIN) was passed through as written. Filenames were also kept in full, and an exported document is often named after a customer. Both are now masked, while module names and line numbers in stack traces are preserved so crash reports stay useful.

## [3.2.0-beta.25] - 2026-07-20

### Fixed

- **Customer data export and deletion could reach the wrong customer.** When two customers shared a contact detail — a family email, a company phone, or just a common name — exporting one customer's data could include the *other* customer's intake submissions, and a full erase could delete them. Khayt now treats a submission's own customer link as final, and only falls back to matching an unlinked submission by email or phone — never by name alone. If you have used **Export this customer's data** or **Full erase** on customers with shared contact details, the results may have been wider than intended.

## [3.2.0-beta.24] - 2026-07-20

### Fixed

- **Camera: a stream-only printer no longer strains the app.** If you configured a camera with only a stream address (no still-image address), Khayt tried to read the never-ending video stream as if it were a single photo, holding it in memory until the request timed out. Those cameras now display the live stream directly, which is what they were always meant to do. Khayt also checks a camera's response size *before* loading it, rather than after.

## [3.2.0-beta.23] - 2026-07-20

**Pre-release (beta) — security hardening.**

### Fixed

- **An API token could reach pages outside its permissions.** Tokens correctly enforced their scopes on data (an orders token could never touch clients), but a valid token also satisfied the owner-PIN check on pages that sit outside the permission model — so a token granted only "machines: read", for example, could open the LAN kiosk page. No shop data was exposed (every data endpoint was, and remains, scope-checked), but it was wider access than intended. A token now stands in for your PIN **only** on the endpoints its scopes actually cover; anything else still asks for the PIN.

## [3.2.0-beta.22] - 2026-07-20

**Pre-release (beta) — printer cameras.** See what your printers are doing, without your video leaving your network.

### Added

- **Per-printer camera view.** Each machine can now show a **live snapshot on its card**. Turn the camera on per printer in the machine editor, hit **Detect from printer** to fill in the addresses automatically for OctoPrint and Moonraker/Klipper setups, and rotate or flip the image if your camera is mounted sideways. The video **stays on your own network** — Khayt reads it directly from the printer's own address and never routes it through any cloud. Cameras are **off by default**, per machine.

## [3.2.0-beta.21] - 2026-07-20

**Pre-release (beta) — webhook retries now survive a restart.**

### Changed

- **Webhook retries are no longer lost when you close Khayt.** Previously a delivery waiting to be retried lived only in memory, so quitting the app dropped it. Pending retries are now saved with your data and **resumed the next time Khayt starts** — including any whose turn came around while the app was closed. A retry whose destination you've since deleted is discarded rather than retried forever.

## [3.2.0-beta.20] - 2026-07-20

**Pre-release (beta) — optional crash reports.** Off by default, separately consented, and scrubbed of anything personal.

### Added

- **Optional crash reports and anonymous usage counts.** Khayt still sends **nothing by default**. If you want to help fix bugs, **Settings → Crash Reports & Usage** offers two independent switches: share scrubbed crash reports, and/or share anonymous usage counts. Before anything is even written to disk it passes a scrubber that strips emails, phone numbers, IBANs, long digit runs and file paths, masks anything key-shaped like an API key or PIN, and then rebuilds the report field-by-field from a fixed allowlist — so your orders, customers, prices, files and secrets can't be included even by mistake. There's no account or user id, just a random install identifier created when you opt in and **erased the moment you opt out** (which also deletes anything queued, straight away). **"View what's collected"** shows you the exact payload. See docs/KHAYT-3.0-TELEMETRY-SPEC.md.

## [3.2.0-beta.19] - 2026-07-20

**Pre-release (beta) — webhook subscriptions.** Send the same shop event to as many places as you like, with automatic retries.

### Added

- **Webhook subscriptions with retries and a delivery log.** Outbound webhooks are no longer one URL per event — you can now point a single event (an order shipped, a payment received) at **several destinations at once**: Slack, a Google Sheet via Zapier, and your own endpoint, all together. Each subscription gets its own signing secret, listens to whichever events you choose, and can be switched off without deleting it. **Failed deliveries retry automatically** with a widening gap (immediately, then 30 seconds, 2 minutes, 10 minutes, an hour), and a destination that replies "gone" is disabled rather than retried forever. Every attempt is written to a **delivery log** so you can see what was sent, what came back, and resend by hand. Your existing webhook setup migrates across automatically — nothing to reconfigure. See docs/KHAYT-3.0-PUBLIC-API-SPEC.md.

## [3.2.0-beta.18] - 2026-07-20

**Pre-release (beta) — automation API.** Give a script or automation tool scoped access to your shop, without handing over your PIN.

### Added

- **Scoped API tokens + a versioned `/v1` API.** You can now connect automation tools (Zapier, Make, your own scripts) to Khayt over the local API without sharing your owner PIN. Mint a token in **Settings → API Tokens**, tick exactly the permissions it should have — orders, clients, inventory or machines, read or write — and it gets nothing else. A read-only token that tries to write is refused with a clear message naming the permission it would need. Tokens are shown **once** and stored only as a hash, so a leaked backup can't be replayed; revoking one takes effect immediately. All existing routes are now also served under a documented, stable `/v1` path, while the old `/api` paths keep working unchanged for the iOS companion and the LAN web app. Works fully offline on your own network. See docs/LAN_API.md.

## [3.2.0-beta.17] - 2026-07-20

**Pre-release (beta) — assembly tracking.** Track each printed part of an assembly through QC, and only complete the order once it's genuinely assembled.

### Added

- **Assembly production tracking.** Products built from several printed parts plus components now track **each part's progress** — pending, printing, printed, QC passed or failed — from a new **Assembly** panel on the job card. The order shows a rolled-up state (in progress → printed → assembled), and an assembly **can't be marked complete until every part has passed QC and you've ticked "Assembled"** — with a message naming exactly which parts are still outstanding. If one part fails QC you can **reprint just that part**; the rest of the assembly is untouched. Ordinary single-part and multi-part orders are completely unaffected. Completes docs/KHAYT-3.0-BOM-SPEC.md §5.

## [3.2.0-beta.16] - 2026-07-19

**Pre-release (beta) — customer privacy.** Consent at intake, one-click customer data export, and a clear choice when erasing a customer.

### Added

- **Customer privacy tools (PDPL / GDPR-ready).** Khayt now gives you the tools to meet your obligations as the data controller for your customers' details. Your public intake form asks customers to **agree to a plain-language privacy notice** before submitting, and records that consent with a timestamp and the exact wording shown. In Clients you can **export one customer's complete data** as a portable JSON file (their record, orders, communications and intake submissions), and **deleting a customer now offers a clear choice**: *unlink* — remove the customer but keep the orders you may be legally required to retain — or *full erase*, which also blanks their name on those orders and purges their intake submissions and communication log. An optional **retention setting** anonymizes the contact details on old intake submissions while keeping the request record. All local, on your machine. See docs/KHAYT-3.0-PRIVACY-COMPLIANCE-SPEC.md.

## [3.2.0-beta.15] - 2026-07-19

**Pre-release (beta) — assemblies.** Products can now be built from printed parts *plus* real components, with the cost and stock handled for you.

### Added

- **Assemblies: products made of printed parts *plus* real components.** A catalog product can now list **non-printed components** — magnets, screws, threaded inserts, packaging — alongside its printed parts. Pick them from your consumables with a quantity per assembly, and Khayt folds their cost into the product's price automatically and **draws the right stock when the order completes** (quantity × the number of assemblies), warning when a consumable runs low. Quoting an assembly carries its component list onto the order. Products with no components behave exactly as before. Runs locally. See docs/KHAYT-3.0-BOM-SPEC.md.

## [3.2.0-beta.14] - 2026-07-19

**Pre-release (beta) — shipping & fulfillment.** Close the order lifecycle with carrier tracking and live customer shipping status, manual-first and fully offline.

### Added

- **Shipping & fulfillment (Saudi carriers).** Close the order lifecycle: a **Ship** action on completed orders records the carrier, tracking number and shipping status right on the order, and the customer sees live shipping status on the same tracking link they already use. **Manual-first and fully offline** — type a carrier + tracking number by hand with zero setup — with an **opt-in** path for **SMSA, Aramex and Saudi Post (SPL)** to auto-create labels (when configured) and receive live status updates via signed carrier webhooks. Shipping status advances through label-created → in transit → out for delivery → delivered (a delivered update also marks the order delivered), never regressing on an out-of-order update. Carrier credentials are encrypted and masked on export; the customer tracking page shows only status, carrier, tracking number and a carrier deep link — never internal cost or notes. Adding a fourth carrier is a one-entry drop-in. Runs locally; carrier APIs are opt-in. See docs/KHAYT-3.0-SHIPPING-SPEC.md.

## [3.2.0-beta.13] - 2026-07-19

**Pre-release (beta) — less typing, smarter defaults.** Pick your printer from a built-in catalog, stop re-entering it in the calculator, and get automatic pricing on catalog products.

### Added

- **Pick your printer from a built-in catalog.** Adding a machine now offers a searchable **Printer model** field covering popular printers (Bambu, Prusa, Creality, Anycubic, Elegoo, Sovol, Snapmaker, QIDI, Voron and more) — choosing one auto-fills the nozzle size, build volume, colour slots, extruder type and typical power draw so you no longer hand-enter specs. If you have a slicer installed, its full printer list (2000+) is folded in too. Runs locally.

### Changed

- **Assign a machine, skip re-typing the printer.** Selecting a machine in the calculator now auto-fills the printer name and its power draw from that machine, so a printer you already defined isn't entered a second time. Saved presets still override.
- **Catalog products get a price automatically.** The product editor now computes a **default price** live from the parts' cost and your margin (the same math as the calculator) and stores it with the product — adding a product no longer needs a separate quoting step. Runs locally.

## [3.2.0-beta.12] - 2026-07-19

**Pre-release (beta) — quality control, reprints & warranty.** The QC stage becomes a real inspection gate, with defect logging, correctly-accounted linked reprints, and customer warranty (RMA) claims.

### Added

- **Quality control, reprints & warranty (RMA).** The existing QC stage becomes a real inspection gate. Record a **pass** (optionally with the inspector who signed off) or a defect-tagged **fail** (failure type, severity, notes, wasted weight) right on the order. A failed job can be **scrapped** or turned into a **linked reprint** — a fresh order that points back at the one it replaces, so material accounting never double-counts: the wasted filament stays booked as waste, and the reprint deducts its own filament only when *it* passes. Reprints are **shop-cost** (no charge — our defect) or **billable** (customer-caused) at a click. For a delivered order, **Open RMA** records a warranty claim (auto-suggesting whether it's within your warranty window) and can spin off a no-charge replacement reprint. New Analytics tiles show QC pass rate, first-pass yield (reprint chains collapse to one job), defect categories, and warranty cost. All opt-in via **Settings → QC**, fully offline, and off by default — with QC off the stage behaves exactly as before. See docs/KHAYT-3.0-QC-SPEC.md.

## [3.2.0-beta.11] - 2026-07-19

**Pre-release (beta) — maker-tools depth.** Following beta.10's "maker tools for everyone," the print-file library, converter and colour tools gained organization, single-extruder colour work, and wider slicer support.

### Added

- **Print-file library: folders and tags.** Print files can now be organized two ways — a single **folder** per file (one-per-file collections) and multiple **tags** (labels a file can share). A filter bar above the grid browses by folder — with per-folder counts and an "Unfiled" bucket — and tags filter alongside it. Folder chips on each card are clickable to filter, and a filter that loses its last matching file clears itself so the grid can't stick on an empty view. Runs locally.
- **Bulk import to the print-file library.** The library's **Add** action now takes a multi-file selection, so you can pull in a whole batch of print files in one step (each gets an auto-generated preview) instead of adding them one at a time. Runs locally.
- **Single-extruder colour-swap plan (M600).** A vertically colour-banded 3MF could previously only get a swap plan for the Snapmaker U1's four heads. A new **Colour-swap plan…** action in the Converter now produces an exact-colour plan for any single-extruder (or pause-capable) printer: the starting colour, a list of swap heights with colour swatches, and a ready-to-use OrcaSlicer `custom_gcode_per_layer.xml` to save or copy. It explains clearly when a model can't be reproduced this way (colours that share layers need a multi-material printer). Runs locally.
- **Colour Studio matches against a bundled filament catalog.** Colour matching no longer dead-ends on an empty inventory — it falls back to a built-in filament catalog so you always get a suggested match to start from. Runs locally.

### Changed

- **Calibration Assistant writes a tuned OrcaSlicer filament profile.** After a calibration pass, the assistant can now save the dialled-in values (temperature, flow, retraction, first layer) straight to an OrcaSlicer filament profile, so the tuning lands in your slicer instead of staying on screen. Runs locally.
- **Filament-profile install supports any Orca-family slicer.** Installing Khayt's filament profiles is no longer limited to Snapmaker Orca — it now targets any Orca-family slicer and printer, and the copy no longer implies Snapmaker-only. Runs locally.

### Fixed

- **Converter batch hardening.** A batch conversion now guards against mixing source ecosystems (files from another printer's slicer are saved as a Generic 3MF with a clear note rather than silently mis-targeted), and the batch panel's controls are locked while a run is in progress so a mid-run change can't corrupt the queue. Runs locally.

## [3.2.0-beta.10] - 2026-07-09

**Pre-release (beta) — maker tools for everyone, plus a tougher converter.** The 3D-printing toolset that used to live behind "Enthusiast" mode is now simply part of Khayt, and the converter gained a 3D preview, a calibration helper, and real hardening against malformed files.

### Added

- **3D model preview.** The Converter and Print-File library now render a rotatable 3D view of a model (WebGL, with a mesh fallback) so you can see what you're about to convert or print — no slicer round-trip. Runs locally.
- **Calibration Assistant.** A new guided helper for dialling in a printer (temperature towers, flow, retraction and first-layer checks) is now available in Khayt. Runs locally.
- **Full Spectrum on custom printers.** If you define a **custom printer profile** for a mixing-capable machine, you can now opt it into Full Spectrum (mixed-filament) conversion — previously only the built-in Snapmaker U1 could mix.

### Changed

- **"Enthusiast" is retired as a mode — its tools are now core features.** The 3MF converter, Colour Studio, print-file library, slicer detection and printer profiles are available in **both Simple and Professional** modes; there's no separate hobbyist mode to pick. Any existing Enthusiast user is migrated to Simple automatically (nothing is lost — the maker tools all stay). The mode picker is now a clean Simple / Professional choice.
- **Bed-fit check now works on "split" 3MF files.** Files that keep their geometry in separate model parts (common in Bambu/Orca exports) now get a proper does-it-fit-the-bed verdict instead of none.

### Fixed

- **Hardened the converter against malformed 3MF files.** A crafted file could previously make the converter do an enormous amount of work (a self-referencing component "bomb", or a palette declaring thousands of colours) and stall the app. The converter now bails safely and quickly on both, and a real painted mesh is verified to survive Full Spectrum with its geometry and colours intact.

> Note: the maker toolset in this release also ships as **Bed Ready**, a separate standalone app for makers. Khayt itself is unchanged in scope — it just no longer hides these tools behind a mode.

## [3.2.0-beta.9] - 2026-07-05

**Pre-release (beta) — prune archived orders.** Keep the app fast as your history grows into the thousands.

### Added

- **Prune archived orders (Settings → Data).** A new maintenance action exports every **archived** order to a dated JSON file and then removes those orders from the live store — so a long-running shop can keep its working data lean without losing history. The export always runs first (the file is your keepsake copy), the removal is behind a clear confirmation, and it only ever touches orders you already archived. The cleanup syncs like any other change (removed orders won't reappear on other devices). Runs locally.

## [3.2.0-beta.8] - 2026-07-05

**Pre-release (beta) — 3MF → STL.** Round out the converter: pull the raw mesh back out of any 3MF.

### Added

- **Export a 3MF to STL.** A new **3MF → STL** action in the Converter tab extracts the mesh geometry from a 3MF — resolving nested components, build transforms, and units — and saves it as a standard binary STL. Pairs with beta.7's STL → 3MF so you can move a model both directions without a slicer. Geometry is preserved exactly; runs locally.

## [3.2.0-beta.7] - 2026-07-05

**Pre-release (beta) — STL → 3MF.** Bring plain STL files into the 3MF workflow.

### Added

- **Convert an STL to a 3MF.** A new **STL → 3MF** action in the Converter tab wraps any STL's mesh into a clean, standard 3MF and adds it to your Print-File library (with an auto-generated preview). The result opens in any slicer, and — like every conversion — your geometry is never altered, only re-packaged. Works locally.

**Pre-release (beta) — saved conversion presets.** Stop re-picking the same target and colour mapping every time.

### Added

- **Conversion presets.** In the convert dialog you can now **save** your chosen target printer (and colour→slot mapping) as a named preset, then **apply** it with one click on any file — the colour mapping is reused when it fits the file's colour count. Manage your presets (list and remove) in the Converter tab. Saved locally.

**Pre-release (beta) — a smarter, safer converter.** Two converter improvements: it now tells you which spool to load for each colour, and it double-checks its own output.

### Added

- **"Nearest in stock" hint per colour.** When you map a multicolour file's colours to slots, each colour now shows the closest filament **you actually have in stock** (by perceptual colour distance, ΔE) — so you know which spool to load into each slot. Uses your inventory's colours and the same colour-matching maths as the Colour Studio.
- **Output self-check.** After converting, Khayt re-opens the file it just wrote and confirms it still parses with its geometry (and, for a retarget, its colours) intact. If anything looks off, it warns you to check in your slicer before printing — cheap insurance behind the "it always opens" guarantee.

**Pre-release (beta) — scale & performance.** Follow-up to the store audit: keep the app fast as your order history grows into the thousands, and stop internal sync data from growing without bound.

### Changed

- **Faster lists and reports with large datasets.** Order, dashboard, kanban and analytics views used to scan the whole client list once for every row/section they drew — so with thousands of orders and clients, rendering slowed down noticeably. Lookups now use fast in-memory indexes, so drawing a list is roughly proportional to what's on screen, not to the size of your whole database. The lead-source revenue breakdown in Analytics in particular went from re-scanning every order for every source to a single pass.
- **Sync delete-markers no longer grow without limit.** Internal "tombstone" records (used to propagate deletions to your other devices during cloud sync) are now capped to the most recent set, so they can't slowly bloat your data file over time.

**Pre-release (beta) — data-safety hardening.** Follow-up to the store audit: make the local data file resilient to crashes and power loss, and stop a bad read from ever overwriting good data.

### Fixed

- **A corrupted or half-written data file can no longer be overwritten with empty data.** Previously, if the store failed to read (a disk hiccup, a partial write), the app started on empty state and the next save would clobber the original — losing everything. Now an unreadable file is **quarantined** (renamed aside, never overwritten) so it's kept for recovery, and the app **automatically recovers** from a completed-but-unswapped temporary write or the previous saved version, with a message confirming your data was restored.
- **The app no longer starts fresh after a crash that left the file mid-swap.** Loading now also checks the temp and previous-generation files, so an interrupted save is recovered instead of looking like a brand-new install.

### Changed

- **Every store write is now atomic and durable.** The data file is written to a temp file and **flushed to disk (fsync) before** being swapped into place, so a power loss can't leave a truncated store; and the previous version is kept as a one-generation rollback (`khayt-store.prev.json`) on every save.

**Pre-release (beta) — correctness & safety pass.** A comprehensive research audit of the data store and the 3MF converter turned up a real data-loss bug and several converter correctness gaps. This release fixes them.

### Fixed

- **Subscriptions and the team activity log now persist.** Retainer/subscription plans (and their recurring-revenue totals) and the entire team **activity log** were being silently dropped on save and came back empty after every restart — the store's save routine only wrote a fixed list of collections and these two weren't on it. Both are now saved and reloaded correctly. (Existing plans/logs that were lost can't be recovered, but new ones stick.)
- **The converter no longer offers incoherent cross-ecosystem conversions.** Retargeting a Bambu/Orca file to a Prusa printer (or vice-versa) can't be done by rewriting metadata — the slicer settings are fundamentally different — but the app used to offer it and produce a file that opened but targeted nothing. The target list now shows only printers compatible with the source file's format; to move between ecosystems, convert to **Generic 3MF** and set the printer up in your slicer. (If a cross-format conversion is triggered another way, the colours are still remapped but the printer settings are left alone, with a clear warning, instead of writing a bad profile.)
- **Retarget now writes the full build volume it promised.** Prusa conversions now rewrite **bed shape and max print height** (not just the model + nozzle), and Bambu/Orca conversions now also write the **printable height** — so the "what changes" summary matches what actually ends up in the file.
- **The bed-fit check is now unit-aware and assembly-aware.** It honours the file's declared unit (a micron- or inch-unit model is no longer mis-measured by 1000×/25×), and it correctly measures multi-part **assemblies** built from components — so it can no longer show a false "Fits" for a model that's actually too big. When the geometry can't be fully measured it now shows no verdict rather than a wrong one.

### Security

- **3MF reader now caps decompression** (guards against a maliciously crafted "zip-bomb" member inflating to gigabytes and crashing the app).

### Changed

- **Deleting a supplier or product now cleans up references.** Removing a supplier un-links it from inventory items and purchase orders; removing a product un-links it from past orders and drops it from any quote bundles — no more dangling references (with one-tap **undo**).

**Pre-release (beta) — a better, more capable 3MF Converter.** Opens the 3.2 cycle by making the converter far more useful before you hit Convert, and adding batch and custom-printer support.

### Added

- **Pre-convert summary + live "what changes" diff.** The convert dialog now reads the source file properly — original **printer, bed, nozzle, layer height, per-colour grams, total material and estimated print time** — and shows a side-by-side **what-will-change** panel (printer → target, bed, nozzle, colours vs the target's slots) that updates as you pick a target, instead of only warning you after the fact.
- **Bed-fit check.** Khayt computes the model's real footprint from the mesh and tells you up front whether it **fits the target printer's build volume** ("Fits" / "May not fit"), with a warning if the footprint or height is too large — so you catch it before slicing, not after.
- **Many more target printers.** The built-in list grew from 8 to 22: added **Bambu H2D, X1E, A1 mini**, **Prusa Core One, MK4S, MK3S+ & MMU2S**, **Creality K1C / K1 Max**, **Qidi Plus4 / X-Max 3**, **Sovol SV08**, **Anycubic Kobra 3**, **FlashForge Adventurer 5M Pro** and **Elegoo Centauri Carbon**.
- **Custom printers.** Define your own printer (name, brand, slicer format, bed X/Y/Z, nozzle, colour slots, model id) in the Converter tab. It's saved locally and offered as a target everywhere the built-ins are — so you can convert for a machine that isn't on the list.
- **Batch conversion.** Pick several 3MF files at once and convert them all to one target printer (or to Generic) in a single run, saving them to a folder or adding them all to your Print-File library, with a per-file progress list and a summary.

### Notes

Geometry is still never touched — the converter only rewrites slicer metadata, so a conversion can't corrupt your model. Everything runs locally.

**Stable release — Khayt for makers, not just print shops.** 3.1 opens the app up to hobbyists and gives everyone a full suite of colour and print-file tools, while keeping the promise that nothing here needs the cloud. It's the culmination of the 3.1 beta cycle (beta.1–beta.15), which also ran a top-to-bottom, three-mode interface review and a final security/correctness hardening pass.

### Added

- **Enthusiast mode** — a third experience alongside Simple and Professional, for personal/hobby printing. It hides everything commercial (orders, clients, invoicing & ZATCA e-invoicing, payments, storefront, customer portal, gift cards) and keeps the personal core: production queue, cost-per-print calculator, filament inventory, printers & monitoring, print-file library, waste log and personal reports. Switch modes anytime with no data loss.
- **Print-File Library** — a standalone, searchable catalogue of your STL / 3MF / G-code files, each with a real preview thumbnail (the slicer's own embedded preview, or a software-rendered 3D view for STL — no cloud), parsed metadata, an optional photo, tags, a tested-settings note, an attached slicer profile, and parsed **multicolour 3MF info** (colours used and swap count). Open any file into your slicer in one click.
- **Colour Mixer suite** — a new **Colour Studio** tab with a **stock matcher** (rank the filaments you own by perceptual closeness / ΔE CIEDE2000, with grams-in-stock and low-stock flags) and a gamma-correct **blend & gradient** tool; a **multicolour print planner** that assigns each of a file's colours to a spool you own, shows per-colour cost and swaps live, and pushes the job into the calculator as one part with the exact blended cost (deducting from each colour's own spool on completion); and a **filament hex input** for pasting exact colour codes.
- **Multiple slicers** — Settings → Slicer holds a list of slicers (name, path, optional command) with a default and per-slicer test, and a **chooser on "Open in slicer"** when more than one is configured. **"Detect installed slicers"** scans your machine (macOS / Windows / Linux) and adds every supported slicer it finds — PrusaSlicer, OrcaSlicer, Bambu Studio, Cura, SuperSlicer, ideaMaker, Simplify3D, Creality Print, Lychee, CHITUBOX, FlashPrint — and runs automatically on first setup.
- **3MF Converter** — a **Converter** tab and a **Convert** action on every 3MF: retarget a multicolour file to another printer (Snapmaker U1, Bambu X1C/P1S/A1, Prusa MK4+MMU3/XL, Creality K2 Plus, Anycubic Kobra S1) with per-colour slot remapping, or produce a clean **Generic 3MF**. Only slicer metadata is rewritten — your geometry is never touched. Converted files stay in-app, attached to the source print file, by default.

### Changed

- **Three-mode interface review.** Every surface was audited for the Enthusiast / Simple / Professional split. Enthusiast mode no longer leaks any commerce (dashboards, themed dashboards, queue cards, calculator, global search, waste log, notifications); Simple gained a focused sales-reports view and no longer showed Professional-only machine-maintenance tools; the profit-margin tile is Professional-only. Every tab is now reachable in all nine themes (Atlas gained a "More" menu).

### Fixed

- **Full UI review** across correctness, visual polish, accessibility (focus-trapped dialogs, accessible names on icon buttons, focus outlines) and RTL, plus dead-code cleanup. **All 3.1 features are now translated in all eight languages** (the parity check was tightened from Arabic-only to all eight), and the in-app updater no longer produces erratic, duplicate or downgrade prompts.

### Security

- Final hardening pass: **SSRF guards on the accounting webhook** (matching the other senders) and a **shell/interpreter blocklist on slicer launch**, so a restored/synced URL or slicer path can't become a request to an internal host or arbitrary code execution.

## [3.1.0-beta.15] - 2026-07-05

**Pre-release (beta) — pre-1.0 hardening pass.** A comprehensive bug, security and UI audit ahead of promoting 3.1 to a stable release. No data-loss or crash bugs were found; the fixes below close real edge-case and mode-separation gaps.

### Fixed

- **Enthusiast (hobbyist) mode no longer shows any pricing in the cost calculator.** The target profit margin, the "✨ Suggest" price helper, the discount field, shipping/extra-charge fees, price tiers, the rush-fee toggle, and the marked-up "Project total" were all still visible. Enthusiast mode now shows **Total cost** only (margin/discount/fees are treated as zero); business modes are unchanged.
- **ZATCA Phase 2 (cryptographic e-invoicing) no longer appears in Simple mode.** It is a Professional-only feature but its onboarding panel was rendering in the Simple invoice settings. (Phase 1 QR invoicing stays available in Simple.)
- **Multicolour planner cost with a resin dominant spool.** A blended multicolour part whose fallback filament happened to be a resin spool was mis-costed by ~1000× (it hit the resin per-kg formula). Blended parts now always use the correct pre-summed material cost.
- **Filament forecast now splits multicolour jobs per spool.** The material-depletion forecast and "queued" totals charged all of a multicolour part's grams to one spool (and zero to the others); they now use the same colour-aware split as reservation and over-commit checks.
- **3MF converter warns when two colours map to the same target slot** (previously one colour was silently dropped).
- **Colour Studio "from filament" picker** now updates the colour swatch for 3- and 8-digit hex inventory colours.
- **RTL polish:** dashboard accent stripes, Atlas floor-card markers and the chart "Download PNG" button now use logical (`inset-inline`/`border-inline`) properties so they mirror correctly in Arabic.

### Security

- **`hub:accounting-push` now applies the same SSRF hardening as the other webhook senders** — private/loopback/cloud-metadata targets, DNS-rebinding and redirects are blocked (the accounting webhook URL comes from the store, which can arrive via restore/sync).
- **Slicer launch rejects shells/interpreters.** The slicer executable (from `settings.slicers[]`, which can be restored/synced) is checked against a blocklist of shells/interpreters (bash, sh, cmd, powershell, python, node, …) before spawning, so a poisoned slicer path can't become code execution on Slice / Open-in-slicer.

## [3.1.0-beta.14] - 2026-07-05

**Pre-release (beta) — dashboard due-date fix + refreshed marketing screenshots.**

### Fixed

- **The Workbench and Vivid dashboards showed a literal "Due in {n}d"** in the "Today's work" list instead of the actual number of days (e.g. "Due in 2d"). The `{n}` placeholder wasn't being substituted for the due-date and overdue labels. Now fixed in both themes.

### Internal

- Screenshot tooling overhauled for the marketing site: the demo store seeds a Print-File library (with real PNG preview thumbnails) so the new 3.1 screens capture non-empty; the capture scripts gate on the demo data actually landing (fixing empty dashboards/queues); and new scripts capture the full website gallery (Workbench/Command/Vivid × EN/AR, including Print Files and Colour Studio) plus a three-modes dashboard showcase.

## [3.1.0-beta.13] - 2026-07-05

**Pre-release (beta) — every installed slicer, not just one.** Khayt now finds the slicers already on your computer instead of expecting you to type a program path by hand.

### Added

- **"Detect installed slicers" in Settings → Slicer.** One click scans your machine for every supported slicer (PrusaSlicer, OrcaSlicer, Bambu Studio, Cura, SuperSlicer, ideaMaker, Simplify3D, Creality Print, Lychee, CHITUBOX, FlashPrint) and adds each one it finds — so when you open a print file, **all** of them are offered, not just a single default.
  - The first time you open the Slicer settings with nothing configured, this scan runs **automatically** and populates the list for you. You can still remove any you don't want, or add one manually.
  - Detection is cross-platform: macOS `/Applications` (resolving each app bundle to its real executable), Windows Program Files / Local App Data, and Linux `PATH`, common bin directories, Flatpak exports and `.AppImage` files.
  - Merging never creates duplicates — a slicer already in your list (by path) is skipped.

## [3.1.0-beta.12] - 2026-07-05

**Pre-release (beta) — converted 3MFs stay with your print file.** Converting a 3MF used to always pop a save dialog and drop the result in whatever folder you picked. Now the conversion is kept **in-app, with the file it came from** by default.

### Changed

- **The 3MF converter now asks where the result should go** — "Keep it with this print file", "Add it to my Print-File library", or "Save to a folder…". The in-app options are the default.
  - Converting from a **library card** attaches the converted 3MF to that same print file. It appears under the card with its own **Open-in-slicer** and remove buttons, and is stored alongside the original in the file's vault.
  - Converting from the standalone **Converter tab** (in-app option) adds the result to your Print-File library as a new entry, with a preview generated automatically.
  - "Save to a folder…" keeps the previous behaviour (choose a location on disk).

## [3.1.0-beta.11] - 2026-07-05

**Pre-release (beta) — mode separation in themed dashboards.** Follow-up to the earlier three-mode work: each visual theme draws its **own** dashboard, and those bespoke dashboards were still showing business figures (revenue, receivables, and a profit-margin %) to **Enthusiast (hobbyist)** users, who should see none. This release cleanly separates the three experiences everywhere.

### Fixed

- **Themed dashboards no longer show revenue, receivables or profit margin in Enthusiast mode.** The **Command, Cockpit, Workbench and Vivid** theme dashboards (and Command's status bar, Cockpit's stats bar) hid revenue "today"/"this month", the "booked"/"unpaid" totals, quote follow-ups, and — on Command — the average **profit-margin %**. Where a money figure sat in a fixed grid, it's replaced with a personal stat (prints today, print hours, prints this month) so the dashboard stays complete rather than leaving a gap. The profit-margin tile is now **Professional-only**; revenue is shown in Simple and Professional.
- **The cost calculator's margin strip** (in the studio/default theme) now shows only the **cost** in Enthusiast mode — the margin %, the "at margin" selling price and the project total are hidden (a hobbyist prices nothing).
- **Customer identity and sale values removed from Enthusiast queue surfaces.** The **Job-Intake funnel** no longer shows client names, per-item estimated value, or the sales "Pipeline value"; the **kiosk display** and every themed queue card drop the client name; and the **quotes-awaiting-approval** strip is hidden entirely in Enthusiast mode.

## [3.1.0-beta.10] - 2026-07-05

**Pre-release (beta) — full UI review, part 3: localization.** The final pass from the interface review closes a translation gap.

### Fixed

- **The whole 3.1 feature set was only in English and Arabic.** The Colour Studio, Print-File Library, 3MF Converter, colour planner and multi-slicer picker — 97 interface strings in total — showed in English for users running the app in **German, Spanish, French, Japanese, Turkish or Chinese** (the parity check only covered Arabic, so the gap went unnoticed). All 97 strings are now translated in every one of the eight languages.

### Internal

- The locale parity check was tightened from "Arabic only" to **all eight languages** — every English string must now be translated in every locale (and keep its `{placeholders}`), so a feature can't ship half-localized again.

## [3.1.0-beta.9] - 2026-07-05

**Pre-release (beta) — full UI review, part 2: visual polish, accessibility & cleanup.** The second pass from the interface review fixes rendering bugs, improves keyboard/screen-reader support, and removes dead code.

### Fixed

- **Kiosk cards and Waiting-list items rendered with no background** in every theme (an undefined colour variable) — now use the standard surface colour.
- **Print-file thumbnails and part-status indicators looked wrong in light themes** — a hardcoded near-black thumbnail placeholder and a couple of hardcoded greys now follow the active theme.
- **The favorite ⭐ button on print-file cards** sat on the wrong side in Arabic (RTL) — now mirrors correctly.
- **A duplicate "quote" status-badge style** (one of two conflicting definitions never applied) was removed.

### Accessibility

- **Pop-up dialogs now trap keyboard focus, move focus into the dialog on open, and restore it on close** (reorder, recovery-code, PIN, delete-confirmation and update dialogs) — previously you could Tab out of them into the page behind.
- **Icon-only delete buttons (× / ✕) across the app now have accessible names** so screen readers announce them.
- Added focus outlines to the studio sliders and the global-search box, an accessible name to the Settings side navigation, and hid a decorative check-mark from screen readers.

### Cleanup

- Removed ~90 lines of dead CSS (old language/theme toggles, superseded badge/grid/mode styles), a dead invoice-number helper, a broken PDF-export progress hook (now wired to the real button), and two leftover debug log lines. No behaviour change.

## [3.1.0-beta.8] - 2026-07-05

**Pre-release (beta) — full UI review, part 1: correctness.** A comprehensive review of the whole interface (mode split, theme shells, RTL, event wiring) turned up a set of real bugs. This release fixes the functional ones; visual/accessibility polish and localization follow in the next betas.

### Fixed

- **Some themes made features unreachable.** In the **Atlas** and **Cockpit** themes several tabs (including the new Print-File Library, Colour Studio and 3MF Converter) had no way to be opened, and in **Workbench / Command / Vivid** those three tools appeared as unlabelled orphan buttons. All tabs are now reachable in every theme — Atlas gained a **"More" menu** for its minimal top bar, Cockpit shows the full set, and the three tools are grouped correctly (and added to Command's icon rail). Switching away from Cockpit no longer leaves its renamed labels on the other themes.
- **Business features leaked into Enthusiast (hobbyist) mode.** The **Production Queue** cards showed Invoice / Mark-paid / Buy-Now-Pay-Later buttons, payment badges, the customer name and the sale price for hobbyists — all now hidden in Enthusiast mode (the cost, hours, parts and delivery controls stay). **Global search** no longer returns orders, clients, products or expenses in Enthusiast mode, and can no longer open the Pro-only Expenses tab from a search result in Simple mode. The **Waste Log** no longer shows the "% of revenue" figure or the per-order table for hobbyists.
- **Waste Log "top orders" table had mismatched headers** — the columns showed order ID and project under "Status" and "Client" headings. Headers now read **Order** and **Product**, matching the data.
- **"Auto-draft POs" toggle** in Inventory is now hidden in Simple/Enthusiast, where the Purchase-Orders surface it feeds is unavailable.

## [3.1.0-beta.7] - 2026-07-04

**Pre-release (beta) — Simple & Professional mode review.** Following the Enthusiast-mode cleanup, the same three-mode review was extended to **Simple** and **Professional**. It found the Analytics/reports tab unreachable in Simple, Pro-only machine maintenance leaking into Simple, and a dashboard widget hidden in the wrong mode.

### Fixed

- **Sales reports now reachable in Simple mode.** The **Analytics** tab was gated Professional-only, so small shops on Simple mode had no reports at all. It now opens in Simple as a focused **sales-reports** view (month revenue, orders, receivables, top products); Professional keeps the full analytics dashboard, and Enthusiast still hides it entirely.
- **Machine maintenance is now Professional-only, everywhere.** The **maintenance log**, **nozzle-change logging**, **service-due / downtime badges** and the **downtime scheduler** were showing on printer rows in Simple mode even though machine maintenance is a Professional feature — they're now hidden unless you're in Professional mode.
- **Production forecast now shows in Simple mode.** The per-printer "estimated time to clear the queue" widget on the dashboard was shown in Enthusiast and Professional but hidden in Simple. It's a personal planning widget (no revenue figures), so it now appears in all three modes.
- **Expense tracking documented as Professional.** The in-app tier comparison now correctly lists **Expense tracking** and **Sales reports** under the right tiers.

## [3.1.0-beta.6] - 2026-07-04

**Pre-release (beta) — Enthusiast mode cleanup.** A review of the three-mode split (Enthusiast / Simple / Professional) found several business features still showing in **Enthusiast (hobbyist)** mode. Enthusiast mode is meant to have no commerce at all; these are now hidden.

### Fixed

- **Business features no longer appear in Enthusiast mode.** The **Product Catalog** and **Analytics** tabs (both commerce surfaces) were visible to hobbyists and are now hidden. The **dashboard** no longer shows unpaid/receivables, aging, quote follow-ups, order revenue or the monthly revenue goal in Enthusiast mode — only your printers, filament, production forecast and today's prints. The **notification bell** no longer raises quote-expiry, recurring-order or installment-payment alerts for hobbyists (overdue jobs, low stock and maintenance reminders still do). The **cost calculator** hides the client picker, client PO/reference, deposit field and "Save as Quote" — leaving the cost maths, printer assignment and "send to queue". Simple and Professional modes are unchanged.

## [3.1.0-beta.5] - 2026-07-04

**Pre-release (beta) — the multi-printer 3MF converter.** The last of the BedReady-style colour tools: take a multicolour 3MF sliced for one printer and retarget it to another, or clean it up into a standard file any slicer opens.

### Added

- **3MF Converter** — a new **Converter** tab (personal core, every mode) plus a **Convert** action on every 3MF in your Print-File library. Pick a target printer — **Snapmaker U1, Bambu Lab (X1C / P1S / A1), Prusa (MK4 + MMU3, XL), Creality K2 Plus, Anycubic Kobra S1** — and Khayt rewrites the file's printer profile (model, bed size, nozzle) for it. For multicolour files you can **remap each source colour to a specific slot** on the target printer. Or choose **Generic 3MF** to strip vendor-locked slicer settings and produce a clean standard file. Your model geometry is never touched by the conversion — only the slicer metadata is rewritten — so a converted file can't come out corrupted; worst case you fine-tune a setting in your slicer. Everything runs locally.

## [3.1.0-beta.4] - 2026-07-04

**Pre-release (beta) — update-system reliability fix.** The in-app updater could behave erratically; this release makes the automatic check as strict and consistent as the manual one.

### Fixed

- **Erratic / duplicate update prompts** — the automatic update notification now goes through the exact same checks as the manual **Check for updates** button. Previously the automatic path could pop the update window for a beta when beta updates were switched off, prompt inconsistently with the manual check, offer an *older* release as a "downgrade update" when running a beta build, or — on a manual check — briefly stack two update windows at once. All of these are resolved; the updater will never offer a downgrade and only prompts for a genuinely newer, allowed release.

## [3.1.0-beta.3] - 2026-07-04

**Pre-release (beta) — multiple slicers.** Many makers run more than one slicer (PrusaSlicer for FDM, a vendor slicer for a particular printer, a resin slicer). Khayt now supports a list of them instead of a single program.

### Added

- **Multiple slicers** — Settings → Slicer now holds a list. Add each slicer you use (name, program path, optional slice command), mark one as the **default**, and test each one. Your existing single-slicer setup is migrated automatically and keeps working everywhere it did before (slice-and-print from the queue, machine slice, quote slicing all use the default).
- **Slicer chooser on open** — when you have more than one slicer configured and hit **Open in slicer** on a print-file library card, Khayt asks which one to launch and remembers your choice for that file. With a single slicer configured, it opens straight away as before.

## [3.1.0-beta.2] - 2026-07-04

**Pre-release (beta) — the Colour Mixer suite.** Turns the colour every filament already stores, and the multicolour data parsed from 3MF files, into a set of colour tools for makers. Personal core: available in every mode, including Enthusiast.

### Added

- **Colour studio** — a new **Colour** tab (personal core, in every mode). It has two panels: a **stock matcher** that takes any target colour and ranks the filaments you actually own by perceptual closeness (ΔE / CIEDE2000 — the same distance metric print shops use), showing each one's grams in stock and a low-stock flag; and a **blend & gradient** tool that mixes two colours (gamma-correct, in linear light) and builds an N-step gradient for ombré or colour-swap plans, annotating every step with its nearest in-stock filament. Click any swatch to copy its hex.
- **Multicolour print planner** — from any print-file library card that carries more than one colour (or from the Colour tab), assign each of the file's colours to a filament you own — defaulting to the closest ΔE match — tune the grams per colour, and see per-colour cost and the file's swap count live. **Add to calculator** pushes the whole thing into the cost calculator as a single part with the exact blended material cost, and remembers the assignment on the file. When that job later completes, filament is deducted from *each* colour's own spool (with same-material fallback), not just one.
- **Filament hex input** — the colour picker in the add-filament form and the edit dialog now has a paired hex text field, so you can paste an exact colour code (e.g. from a filament maker's spec) instead of eyeballing the swatch.

## [3.1.0-beta.1] - 2026-07-04

**Pre-release (beta) — opens the 3.1 cycle for 3D-printing enthusiasts.** Two foundation features that make Khayt work for hobbyists, not just print shops.

### Added

- **Enthusiast mode** — a new third experience alongside Simple and Professional, chosen in the first-run wizard or Settings → Preferences. Enthusiast mode is for personal/hobby printing: it hides everything commercial (customer orders, clients, invoicing & ZATCA e-invoicing, payments, the online storefront & customer portal, gift cards) and keeps just the personal core — the production queue, cost-per-print calculator, filament inventory, printers & monitoring, the new print-file library, waste log and personal reports. Switch modes anytime; no data is lost.
- **Print-File Library** — a standalone, searchable catalogue of your STL, 3MF and G-code files, independent of any order. Each file gets a **real preview thumbnail** (the slicer's own embedded preview for G-code/3MF, or a software-rendered 3D view for STL — no cloud, no extra dependencies), parsed metadata (print time, filament grams, slicer, dimensions), an optional photo, tags, a "tested settings" note and an attached slicer profile, plus **multicolour 3MF info** (filament colours used and swap count). Open any file straight into your installed slicer in one click. Everything stays on your machine.

**Khayt 3.0 — stable release.** The 3.0 platform is now stable and generally available. Built on the fully-offline core (quoting, Kanban production queue, ZATCA Phase 2 e-invoicing, live printer monitoring, filament inventory and analytics), 3.0 adds an **optional, end-to-end-encrypted cloud** layer — sync, team accounts, an online storefront with checkout and deposits, a customer portal, remote mobile access, and an AI assistant — none of which is required to run the app. This release is the culmination of the 3.0 beta cycle (beta.1–beta.21): it ships all 8 interface languages fully translated, a fixed first-run onboarding wizard, and a full release-candidate hardening pass that verified fresh-install, large-dataset (3,000 orders), all-10-designs, and all-locale rendering with zero runtime errors.

### Added

- **All 8 interface languages now fully translated** — German, Spanish, French, Japanese and Chinese join English, Arabic and Turkish at full coverage (every one of the ~3,150 UI strings). Previously these five each fell back to English for ~210 strings; now the entire interface renders in your chosen language. A 1.0 readiness step toward a polished international release.

### Fixed

- **First-run onboarding** — a brand-new install now correctly shows the setup wizard. (The default starter inventory was making a fresh shop look "already set up", which skipped onboarding for first-time users.)

## [3.0.0-beta.20] - 2026-06-26

**Pre-release (beta)** — a stability & accessibility release from a full UI review: a form-label accessibility pass (every field now announces its purpose to screen readers), a fix for the Settings market/locale pickers, and corrected release screenshots. Verified clean for RTL/Arabic, narrow-window layout, and runtime errors across every screen.

### Accessibility

- **Form fields announce their purpose** — every input and dropdown is now programmatically tied to its label, so screen readers announce what each field is (previously ~39 fields across the calculator, inventory, logs, analytics, waste and settings had a visible label that wasn't linked to the control). Filter dropdowns also gained accessible names, and the Orders log status/payment filters now read **"All statuses" / "All payments"** instead of a bare "All" — clearer both on screen and to assistive tech.

### Fixed

- **Settings market & locale selectors** — fixed a startup error (`KhaytIntegrations.forLocale is not a function`) caused by two modules claiming the same global name, which left the storefront/payment **integration market pickers** in Settings empty. The market registry now owns that name; the integrations feature module no longer clobbers it.

- **Release/README screenshots** — the auto-captured headline **dashboard screenshot** could render blank because the capture started before the demo data finished loading. The capture now waits for the data to actually apply, so every published screen shows real content.

## [3.0.0-beta.19] - 2026-06-25

**Pre-release (beta)** — power-user & polish release: plate-nesting batch suggestions, a custom report builder, per-field coach tips, smart expense categorization, portal messaging, signed developer webhooks, cross-device cloud snapshot history, and a fully translated Turkish interface.

### Added

- **Complete Turkish interface** — the Türkçe locale is now **fully translated** (the whole UI, not just the core subset), so nothing falls back to English when you pick Turkish. Brings tr to parity with English and Arabic.

- **Cloud snapshot history** — your shop is now **versioned in the cloud** on every sync. Open **Settings → Khayt Cloud → 🕑 Snapshot history** to see prior versions and **restore any of them in one click** — the chosen version replaces local data on this device and syncs to your others. Still fully end-to-end encrypted; the server only ever stores opaque ciphertext. Extends beta.18's local restore points across devices. Requires cloud sync.

- **Signed event webhooks (for developers)** — point one HTTPS endpoint at Khayt and receive a clean, **HMAC-signed** `order.*` event stream (created / status changed / fully paid) with an idempotency key, so you can build your own integrations and trust each payload via the `X-Khayt-Signature` header. Configure under **Settings → Signed Event Webhooks**; off by default. Complements the existing per-event (Zapier/Make) webhooks.

- **Portal messaging** — customers can now message you right on their order/quote portal page, and you reply from the order menu (**💬 Portal messages**) — a simple shared thread for questions, approvals, and updates. You're notified (email + push) when a customer writes. Requires cloud sync.

- **Smart expense categorization** — when you type an expense note, Khayt suggests the right category (Filament, Electricity, Maintenance, Shipping, Tools) with one tap to apply. Works offline and understands English + common Arabic terms.

- **Coach tips** — small ⓘ help icons now sit next to key inputs (profit margin, failure rate, VAT %, machine wear) explaining what they mean and how to set them — handy when you're starting out. Toggle them off anytime in **Settings → Data**. Completes the onboarding work from the guided tour.

- **Custom report builder** — build your own order reports (Analytics → **Report builder**): pick the columns you want, filter by status and date range, preview live, and export to CSV. Save report definitions and re-run them with one click.

- **Plate nesting / batch suggestions** — the Batch Planner can now **auto-suggest build plates**: it packs your selected (or all pending) jobs into efficient batches by material and a configurable max print-time and weight per plate, so you can run several jobs per build instead of one at a time. Jobs too big for one plate are flagged.

## [3.0.0-beta.18] - 2026-06-24

**Pre-release (beta)** — a polish & launch-readiness release: invoice templates, a monthly email digest, overdue-invoice reminders, a guided tour, a Turkish interface, an accessibility pass, named restore points, and a Road-to-1.0 plan.

### Docs

- **1.0 launch-readiness pass** — refreshed the pre-launch QA checklist (`docs/PRELAUNCH-QA.md`) with the beta.16–18 features and current coverage counts, and added a **Road to 1.0** release-candidate plan (feature freeze → full QA → `rc.1` tag → soak → promote to `v3.0.0`). Full sweep verified green: 674 desktop tests, 61 cloud contract tests, e2e smoke, lint.

### Added

- **Named restore points** — save a **labeled snapshot** of all your data (Settings → Backups → Restore points…) before a risky change like a big import or month-end, and **roll back in one click** anytime. Restore points are kept separately from the dated auto-backups (so they're never auto-pruned), encrypted on disk, and capped at the most recent 50.

### Accessibility

- **Keyboard & screen-reader pass** — a visible keyboard **focus ring** now appears across all interactive controls (buttons, inputs, selects, links, tabs), and a **“Skip to main content”** link lets keyboard and screen-reader users jump past the nav. Mouse interaction is unchanged (focus rings show only for keyboard navigation).

### Added

- **Turkish (beta)** — Khayt now offers a **Türkçe** interface option (top-bar language switcher, Settings, and setup wizard). The core navigation, common actions, order statuses, and tour are translated; remaining strings fall back to English while translation continues — bringing the supported language count to 8.

- **Guided tour** — first-time owners now get a quick walkthrough after setup that steps through the dashboard, calculator, queue, inventory, clients, and analytics with a short explanation of each. Replay it anytime from **Settings → Data → Take a tour**. (Adapts to Simple/Pro mode and works in both English and Arabic/RTL.)

- **Overdue-invoice reminders** — opt in (Settings → Automation) and Khayt periodically flags unpaid invoices past their due date — with a configurable grace period, cooldown, and per-invoice cap — so you can send a payment reminder in one tap from the dashboard. Complements the existing quote follow-up automation; it never messages customers automatically.

- **Monthly email digest** — the automated email digest (Settings → Email digest) now supports a **Monthly** cadence on a day-of-month you choose, alongside daily and weekly. It emails the period's revenue, outstanding balance, completed orders, low-stock spools, and intake — so you get a month-end business summary in your inbox automatically.

- **Invoice templates** — pick a document look in **Settings → Business**: **Classic** (the current style), **Modern** (a bold accent-coloured header band), or **Minimal** (clean, no colour bar). It restyles your invoices, quotes, and receipts on top of the existing logo, tagline, accent colour, and terms — purely visual, so ZATCA fields and totals are unchanged.

## [3.0.0-beta.17] - 2026-06-24

**Pre-release (beta)** — a usability, finance & scale release: supplier price lists, downloadable portal invoices, mobile inventory, an executive KPI summary, per-location reports, a team activity log, more storefront/payment connectors, and one-click demo data.

### Added

- **Demo data to explore** — new shops can now **Settings → Data → Load demo data** to fill Khayt with realistic sample clients, products, spools, printers, and orders (across quote → printing → delivered) and try every tab before entering real data. One click to **Remove demo data** later — your real records are never touched.

- **More storefront & payment connectors** — the Storefronts & Payments directory grows from 3 to **5 per market**: added Wuilt & ExpandCart (Gulf), BigCommerce & Wix (US/Spain/France), Wix & Etsy (Germany), STORES & MakeShop (Japan), Pinduoduo & Weidian (China) — plus more payment options per market (Tamara, PayTabs, Apple/Google Pay, Redsys, Lydia, giropay, SOFORT, LINE Pay, Merpay, JD Pay, QQ Pay…). New storefronts work with the existing import links and catalog feeds.

- **Team activity log** — a new **Clients → Activity** view records who did what and when (orders & quotes created, status changes), attributed to the signed-in operator, filterable by team member. Pairs with the existing per-operator job assignment and roles, and syncs across devices. (Built on the existing operator sign-in.)

- **Per-location reports** — the Executive summary now has a **location switcher** (All locations / each site), so multi-site shops can see revenue, margin, on-time %, cash, and top clients/jobs for one branch at a time. It defaults to your currently active location and complements the existing per-location queue and inventory views.

- **Executive summary** — a one-screen KPI overview (Analytics → **Executive summary**) with quick date ranges (this month / last month / quarter / year / all): revenue, gross profit & margin, average order value, **on-time delivery %**, cash outstanding, and your **top clients & top jobs** for the period — at a glance, no scrolling through charts.

- **Inventory on your phone** — the mobile web app gains an **Inventory** tab: see every spool sorted by how much is left (low stock first, flagged), and tap one to **deduct or top up** grams on the spot — synced back to the desktop. Requires cloud sync.

- **Download invoice from the portal** — when you publish an order or quote to the customer portal, the page now offers a **Download invoice (PDF)** button that renders a clean printable invoice/receipt — your shop name, VAT & address, the reference, total, deposit/balance, and a PAID stamp — which the customer saves as a PDF straight from their browser.
- **Supplier price lists** — give each supplier a per-material price list (price per kg) in their profile. Reorder drafts and auto-draft purchase orders now use the **cheapest matching supplier price** (and assign that supplier) instead of the spool's own cost — so POs reflect what you'll actually pay and you can compare suppliers.

## [3.0.0-beta.16] - 2026-06-23

**Pre-release (beta)** — a storefront, mobile, operations & finance release: product options, storefront insights, portal balance payment, phone order-request triage, a scheduling forecast, auto-draft POs, subscriptions/retainers, and account/tax-code accounting exports.

### Added

- **Accounting exports: account & tax codes** — the Accounting CSV export (and the accounting-sync webhook) now let you set a **sales account code** and a **tax code**, written into the right columns for each provider — including Xero's `AccountCode`/`TaxType` and Zoho's `Account`/`Tax Name`, which their importers require. Your codes are remembered for next time.

- **Subscriptions & retainers** — bill clients a recurring fee on a schedule (Clients → 🔁 **Subscriptions**): set up plans like a monthly maintenance retainer or a print-credit package (daily → yearly), and Khayt auto-generates the invoice each cycle (catching up if the app was closed), pausing/ending on demand. The panel shows your **monthly recurring revenue (MRR)**. Distinct from recurring orders, which reprint a past job rather than billing a flat fee.

- **Auto-draft purchase orders** — turn on **Auto-draft POs** in Inventory and Khayt will automatically create *draft* purchase orders for materials that have hit their reorder point (based on the demand forecast), skipping anything that already has an open PO so nothing piles up. Drafts only — you review and send them. Runs at startup and when you enable it.

- **Schedule board with completion ETAs** — the Queue → **Schedule** view now estimates *when* each job will be ready: it sequences each printer's queue and projects completion dates from your working hours per day, shows a **"ready by …"** date per machine, and flags jobs that will **miss their due date** (outlined in red). Turns the load bars into an actual forecast.

- **Storefront insights** — your published storefront now tracks **views → add-to-cart → orders**, and the Storefront editor shows the funnel, a **conversion rate**, and your **top products** by orders/carts — so you can see what's drawing interest and what's selling. (Aggregate counts only; no visitor tracking.)

- **Pay outstanding balance from the portal** — when you publish an active order to the customer portal, the page now shows the **balance due** and a **Pay balance** button using your pay link (with the amount filled in), so customers can settle the remainder online — not just the upfront deposit on quotes. "Paid in full" is confirmed via your payment webhook.
- **Triage order requests from your phone** — the mobile web app gains a **Requests** tab (with a live count) where you can **Accept** an incoming order request — it's added to your orders as a quote and synced to the desktop — or **Decline** it, all without opening your computer. Requires cloud sync.
- **Storefront product options/variants** — give a published product selectable options (e.g. *Color: Black, White; Size: S, M*) in the Storefront editor. Customers pick their choices on each product card, the selection shows in the order summary, and it arrives with the order request — so you know exactly what they want.

## [3.0.0-beta.15] - 2026-06-23

**Pre-release (beta)** — a portability, intelligence & resilience release: full CSV data export, real remote control from your phone, a P&L export, AI price suggestions, deeper storefront checkout, per-quote currency, and self-healing offline sync.

### Fixed

- **Launch hardening** — duplicating or re-printing an order now carries its per-quote currency into the calculator (so it isn't silently reset on re-save). Refreshed the pre-launch QA checklist (`docs/PRELAUNCH-QA.md`) to cover all beta.15 features.

### Added

- **Resilient cloud sync (auto-retry when offline)** — if a background sync fails because you're offline or the network blips, your change is kept locally and the app now **automatically retries** with exponential backoff instead of waiting for your next edit. The moment connectivity returns (the device comes back online), pending changes are flushed immediately, and a fresh edit supersedes any queued retry so there's never a double-push.

- **Per-quote currency** — the calculator now has a **Currency** selector so an individual quote/order can be priced in any of the 27 supported currencies, independent of the client's default (handy for one-off international jobs or client-less quotes). "Auto" keeps the existing behavior (client currency, else your base). The chosen currency flows through the invoice/quote document (which already renders in the buyer's currency) and analytics conversions — building on the existing per-client currency and configurable FX rates.

- **Storefront checkout: shipping & tax** — your published storefront now supports **shipping methods** (name + price, e.g. Courier / Pickup) and a **tax/VAT rate**, set in the Storefront editor. Customers pick a shipping option at checkout; the order summary shows shipping, tax, and a correct grand total (deposit and the pay link follow the new total), and the choices carry into the request that lands in your inbox.
- **AI price suggestions** — the calculator's margin field gains a **✨ Suggest** button that recommends a target margin grounded in your shop's own realized history: it finds comparable completed jobs (same material, or all priced jobs when a material is new), shows the median margin and range, and — when AI assist is enabled — adds a one-line rationale and a suggested price. One tap applies the margin to the quote. Works without an API key too (data-driven median).
- **P&L summary export** — the Analytics tab gains a **P&L summary** button that exports a clean income-statement CSV for the **currently selected date range** (all time / this month / quarter / year / custom): orders, revenue, cost of goods sold, gross profit & margin, operating expenses broken down by category, VAT collected, and net profit. Cells are spreadsheet-safe for Excel/Sheets — hand it straight to your accountant.
- **Remote control from your phone** — the mobile web app (sign in at your Khayt Cloud address → unlock with your sync passphrase) gains real control, not just viewing: a new **Printers** tab shows each machine with a live "Printing now / Idle" badge and the job currently on it, and **quotes** can now be **approved or declined** right from the order sheet (approve moves it to pending; decline voids it) — syncing straight back to the desktop. Requires cloud sync.
- **Export all data (CSV)** — a one-click **Settings → Data → Export all data (CSV)** writes a clean CSV per collection (orders, clients, products, inventory, expenses, machines, suppliers, purchase orders) into a folder you choose, alongside the existing JSON backup. Every cell is quoted and formula-neutralized so the files open safely in Excel/Sheets — full data portability for spreadsheets, accountants, or migrating elsewhere.

## [3.0.0-beta.14] - 2026-06-23

**Pre-release (beta)** — a storefronts & payments integrations suite: a per-market directory, two-way storefront order import & catalog publishing, and guided setup.

### Added

- **Storefronts & Payments directory** — a new **Settings → Storefronts & Payments** section lists the top 3 storefronts and top 3 payment systems for each translated market (Saudi/Gulf, US/Global, Spain, France, Germany, Japan, China) — switchable by market. You can enable the payment methods you accept and save your own payment link for each, ready to use at checkout. (First part of the integrations suite; storefront order import & catalog publishing follow.)
- **Storefront order import (inbound)** — connect a store's order webhook to Khayt and new orders land directly in your **Order requests**. Each inbound-capable storefront in the directory now shows a **Copy import link** (once cloud sync is on); paste that URL as an order/checkout webhook in Shopify, WooCommerce, Etsy, Salla, Zid, Shopware, PrestaShop or BASE and incoming orders are mapped to a request automatically (customer, contact, line items, note), tagged with the source platform.
- **Catalog publish (outbound)** — publish your storefront catalog out to other shops. Each outbound-capable storefront now shows a **Copy feed link** (once cloud sync is on) that gives you a product-feed URL — CSV for Shopify/WooCommerce-style importers, an RSS/Google-Merchant feed for ad/marketplace catalogs, or JSON — to paste into the platform's "import products from URL" feature. The feed mirrors your published catalog (names, prices, categories, availability, photos) and refreshes automatically as you update it.

## [3.0.0-beta.13] - 2026-06-23

**Pre-release (beta)** — clearer Simple/Pro modes, onboarding, quote bundles, and a customer self-service portal.

### Added

- **Clearer Simple vs Professional modes** — the mode switch (Settings → Experience) now shows a side-by-side comparison of exactly what each tier includes: the Simple core (quoting, queue, invoices, inventory, clients) and everything Professional adds (full analytics & forecasting, ZATCA, proforma/milestone invoices, purchasing & A/P, multi-location, team accounts, maintenance, loyalty), with your current tier highlighted. Backed by a single canonical feature registry so the boundary is consistent.
- **First-run setup adds your first printer** — the setup wizard now lets you name your first printer during onboarding, so the queue and calculator have a machine ready to go from the start.
- **Quote bundles** — save a named set of catalog products as a **bundle** (e.g. "Desk set") and quote them all into the calculator in one tap (**Catalog → 🎁 Bundles**). Complements the existing per-part volume/tier pricing.
- **Customer self-service portal** — when a customer signs in to their orders link, they can now **re-order** a past job (it lands in your Order requests) and **leave a star review** right from the portal — on top of seeing their orders and statuses.

## [3.0.0-beta.12] - 2026-06-23

**Pre-release (beta)** — scan-in, a deeper storefront, a security/perf hardening pass, and a revenue forecast.

### Added

- **Scan-in workflow** — the camera/barcode scanner now recognises Khayt's own label QR codes: scan a **spool label** to open that spool (quick deduct/top-up), or an **order label** (or its customer tracking QR) to open that order. Works with the camera or a USB/Bluetooth barcode scanner (or just type/paste a code). Closes the loop with the QR labels added in beta.11.
- **Storefront depth** — the public storefront grew up: organise products into **categories** (shown as sections), set a **lead time** and a **minimum order**, and mark items **sold out** — all from **Khayt Cloud → 🏬 Storefront**. The shop page groups by category, shows the lead-time, blocks checkout below the minimum, and tightens the grid on small phones.
- **Revenue forecast** — Analytics now projects your **next three months** of revenue with a trend line fitted to recent months (least-squares regression, falling back to an average when history is thin), shown as a chart with a "projected next month ±%" headline. Distinct from the dashboard's month-to-date estimate.

### Fixed & hardened

- **Team-account security (cloud)** — only the **owner or a manager** can now invite or remove team members (previously any member could), and **removing a member revokes their access immediately** instead of waiting for a password reset.
- **Draft purchase orders** no longer over-state cost (a per-kg price was used as per-gram).
- **Recurring orders** can no longer double-create on a single launch, and a corrupt schedule interval no longer halts the recurring sweep.
- **Auto-assign** now also places `queued` jobs (not just pending).
- **Performance** — the inventory search and the campaign segment preview are debounced, so large shops (thousands of orders) stay smooth while typing.

## [3.0.0-beta.11] - 2026-06-23

**Pre-release (beta)** — grow + operate: marketing campaigns, QR labels, demand-aware reordering with draft POs, and customer reviews.

### Added

- **Marketing campaigns** — broadcast a message to a customer segment over email or WhatsApp/SMS (**Clients → 📣 Campaign**). Segment by minimum lifetime spend, "no order in N days" (win-back), tag, or loyalty tier; personalise with merge fields (`{{name}}`, `{{orders}}`, `{{spend}}`, `{{last_order}}`); see the live recipient count + a preview before sending. Sends are throttled, skip customers who lack the channel's contact, and respect a new per-client **"Exclude from marketing"** opt-out. Reuses your configured email + SMS providers.
- **Label & QR printing** — print QR labels for orders and spools. **Order labels** (🏷 on a queue card) carry a QR that opens the customer's tracking page; **spool labels** (Inventory → 🏷 Labels) encode a scan-in code for the spool. Labels print as an A4 grid on a normal or label printer.
- **Demand forecast & draft purchase orders** — reorder suggestions now subtract grams **already committed to open orders** from on-hand stock, so "days left" reflects the work in your queue (not just past usage) — and a material can surface for reorder when queued jobs alone would exhaust it. A new **"Draft purchase orders"** button turns the suggestions into draft POs (suggested quantity + your per-kg cost), ready to review and send.
- **Customer reviews & ratings** — collect remote reviews: share a review link (**Khayt Cloud → 🏬 Storefront → Copy review link**) after an order and the customer rates you 1–5 ★ with an optional comment on a simple page. Your **average rating + count** shows in the Storefront panel and on the **public storefront**. (Complements the existing on-site survey, which was local-network only.)

## [3.0.0-beta.10] - 2026-06-23

**Pre-release (beta)** — assist + automate: a conversational AI assistant, storefront promo codes, pause/skip/end for recurring orders, and one-way accounting sync.

### Added

- **AI shop assistant — conversational** — the "✨ Ask AI" assistant now holds a **conversation**: it remembers earlier answers in the session, so follow-ups like "and last month?" or "which of those is overdue?" work in context, shown as a chat transcript. Still grounded strictly in your own shop data (no invented numbers) and uses your own Anthropic key.
- **Storefront promo codes** — add discount codes to your storefront (**Khayt Cloud → 🏬 Storefront**): percentage or fixed amount, optional expiry, and an optional usage limit. Customers enter a code at checkout and the total + deposit update live; codes are validated on the server (expiry and usage count are enforced, not bypassable from the page). The applied code and discount are recorded on the order request.
- **Recurring orders — pause, skip, end & accurate scheduling** — recurring orders (per-client) can now be **paused** (keeps the schedule, stops creating), given a **stop-after date**, or **skipped one cycle** — all from the client editor. The next-due date now advances by true calendar months (no more month-end drift), and a background re-check creates due orders even if the app stays open for days (no restart needed). Paused subscriptions no longer show as "due".
- **Accounting sync** — push paid invoices (and a test payload) to a **webhook** so bookkeeping stays in sync without re-entry (**Settings → Accounting Sync**): pick a format hint (Generic / QuickBooks / Xero / Zoho), set the URL + optional shared secret, and choose to push automatically when an invoice is marked paid. Payloads carry VAT split + an idempotency key so re-sends are safe; bridge to your accounting software with Zapier/Make or your own endpoint. Complements the existing accounting CSV export.

## [3.0.0-beta.9] - 2026-06-23

**Pre-release (beta)** — selling + customer comms: storefront checkout & deposits, customer order tracking, automated SMS/WhatsApp updates, and print-farm auto-scheduling.

### Added

- **Storefront checkout & deposits** — your storefront now shows prices and a running cart total, and can request a deposit. Set a price per product, a deposit %, and paste a payment link from any provider (**Khayt Cloud → 🏬 Storefront**); at checkout the customer sees the total, the deposit due, and a **Pay deposit** button (your link, with `{amount}`/`{total}` filled in), then sends the order — which arrives in **Order requests** itemised with the total and deposit.
- **Customer order tracking** — a published order link now shows a visual progress timeline (Received → Printing → Finishing → Done → Ready for pickup) with the current step highlighted, in the customer's language, instead of just a status label. Updates automatically as you advance the order; quotes are unchanged.
- **SMS / WhatsApp notifications** — send automated order updates to customers over SMS or WhatsApp (**Settings → SMS / WhatsApp Notifications**). Pluggable provider — **Twilio**, the **WhatsApp Cloud API**, **Unifonic**, or your own **webhook** — with a Send-test button. Provider credentials are encrypted at rest like your other keys. (The manual "share to WhatsApp" link is unchanged; this adds true automated sending.)
- **Print-farm auto-scheduling** — beyond the existing "Suggest assignments" review, the queue now has a one-click **🪄 Assign** (apply the best machine for every unassigned job immediately) and an **Auto-assign** toggle that keeps queued jobs placed on free, compatible machines automatically (material- and nozzle-aware, load-balanced, skipping offline/in-downtime machines).

## [3.0.0-beta.8] - 2026-06-22

**Pre-release (beta)** — the four community-picked features: filament-at-a-glance, multi-user team accounts, a public storefront, and real Bambu Lab support.

### Added

- **Filament status on the dashboard** — an at-a-glance panel showing spools that are low or projected to run out soon (remaining grams + %, days-left), reusing the existing reorder engine. Complements the inventory tab and low-stock alerts so you spot shortages from the home screen.
- **Team accounts (multi-user)** — invite staff to your shop with a role (manager / operator / viewer). They join with their own email + password via an emailed invite code (and the shop's shared sync passphrase), then share the same cloud data. Manage everyone from **Khayt Cloud → 👥 Team**; roles drive in-app permissions.
- **Public storefront** — publish your product catalog as a shareable public page (**Khayt Cloud → 🏬 Storefront**). Customers browse your products, pick what they want with quantities, and send a request — which lands straight in **Order requests** as a draft quote. Owner-curated plaintext (no account or E2E key needed to view); unpublish anytime to take the link offline.
- **Bambu Lab printers (local network)** — real LAN monitoring + send-to-print for Bambu (P1/X1/A1). Status now comes over the printer's MQTT channel (state, progress, layer, nozzle/bed temps, time left) instead of the old non-working HTTP stub, and **🖨 Slice & print** uploads the file over FTPS and starts it. Set the printer's **IP, access code and serial** (Settings → machine → Live API). No cloud account or SDK required — it talks straight to the printer on your network.

## [3.0.0-beta.7] - 2026-06-21

**Pre-release (beta)** — reliability + project move.

### Added

- **Crash reporting (opt-in, privacy-safe)** — official builds report crashes and errors to Sentry so issues are caught fast. No personal data or your encrypted store is ever sent; it's active only in installed builds (off during local development) and off entirely in source/fork builds without the project key.

### Changed

- Khayt now lives in the **`khaytapp` GitHub organization**; release downloads and auto-updates moved with it (old links auto-redirect). The contact address is now on `khaytapp.com`.

## [3.0.0-beta.6] - 2026-06-20

**Pre-release (beta)** — the slice → print pipeline. Configure your slicer, then send jobs to the printer without leaving Khayt.

### Added

- **Slice & print** — on a machine with a printer API (OctoPrint / Moonraker / PrusaLink), a 🖨 button slices a chosen model with your installed slicer and **uploads + starts the print** on that machine. You can also send an already-sliced `.gcode` directly (no slicing).
- **Slice & print from the queue** — a pending order whose assigned machine has a printer API and an attached model/G-code gets a 🖨 action right on the kanban card: slices the attachment (or uploads it) and starts it on that printer.
- **Slicer "Test" button** (Settings → Slicer) — verifies the configured slicer program runs before you rely on it.

## [3.0.0-beta.5] - 2026-06-20

**Pre-release (beta).** Also relicensed to the Functional Source License (FSL-1.1-Apache-2.0): free to use (incl. for your business), source-available, no reselling/hosting, and each release auto-converts to Apache-2.0 after two years. See [LICENSE](./LICENSE).

### Added

- **Slicer integration** — point Khayt at your installed **PrusaSlicer / OrcaSlicer** (Settings → Slicer), then **"🧩 Slice for exact quote"** in the calculator slices an uploaded model and fills print weight + time from the slicer's *own* estimate (parses time/filament/cost from the G-code). Khayt never bundles a slicer — it shells out to yours, so it stays license-clean. Complements the offline STL geometry estimate.

## [3.0.0-beta.4] - 2026-06-20

**Pre-release (beta)** — four growth features: live printer monitoring, customer order intake, STL-based quoting, and web push.

### Added

- **Live printer panel on the dashboard** — an at-a-glance card showing every API-connected machine's state, print progress, hotend/bed temps, current file, and ETA, refreshing in place each poll (reuses the existing OctoPrint/Moonraker/Klipper/PrusaLink/Bambu poller). Complements the kanban's per-machine live status.
- **Customer order intake** — share a request link (`…/intake/<shop>`) and customers submit a print request (project, description, quantity, material, model link, photo, contact) with no login. New requests arrive in **Khayt Cloud → Order requests**; one click turns a request into a draft quote with a linked client. You're emailed when one comes in.
- **Estimate from a 3D model (STL)** — in the calculator, upload an STL and Khayt reads its geometry (volume + bounding box) to auto-fill print weight and time using your infill setting; it shows the size, solid vs estimated weight, and the assumptions so you can adjust before saving. Works fully offline; handles binary and ASCII STL.
- **Web push notifications** — install the remote-mobile app (PWA) and tap **Enable alerts** to get a push on your phone when a customer approves/declines a quote, pays a deposit, or submits an order request — even with the app closed. Payload-less (VAPID): the push service never sees your data. Requires the operator to set a VAPID key on the cloud.

## [3.0.0-beta.3] - 2026-06-20

**Pre-release (beta)** — a hardening pass from a full UI / language / security / bug audit. No new features; everything below makes 3.0 safer and more complete.

### Security (Khayt Cloud)

- **Customer portal sign-in required for quote decisions** — approving/declining a quote linked to a customer account now requires that signed-in customer, so a forwarded link can't be used to forge a decision. Unlinked links keep the one-tap flow.
- **Faster, abuse-resistant auth** — device-token and portal-session lookups no longer verify every stored hash (a denial-of-service hazard); they match a single indexed row.
- **Rate-limit hardening** — the limiter no longer trusts a spoofable `X-Forwarded-For`, so brute-force protection on sign-in / reset / portal can't be bypassed.
- Added HSTS + Content-Security-Policy + clickjacking protection to the portal and mobile pages; admin endpoints are header-only (no secret in the URL); `customerEmail` is validated before an item is linked to a customer.

### Fixed

- **Plan expiry** is now compared in UTC consistently, so a subscription can't read as expired (or active) by the server's timezone offset.
- **Billing plan updates** target the exact account (by email or id), never an unintended match.
- **Remote-mobile app** locks immediately when you switch away/lock the phone (it previously extended the unlock window).
- Dark-theme fix: the "email not verified" notice is now readable (was a light box on dark cards).

### Internationalization

- **Full translation parity across all 7 languages** — backfilled ~200 missing strings (cloud, AI assistant, quote estimator, maintenance, reorder, …) into German, Spanish, French, Japanese, and Chinese, plus 22 more previously-English strings (referral analytics, feedback modal, order notes, purchase-order headers). Nothing falls back to English anymore.
- **Customer portal + remote-mobile** are fully localized (English/Arabic with RTL); the server-rendered status page now matches the dark portal theme.

## [3.0.0-beta.2] - 2026-06-20

**Pre-release (beta)** — growth + customer-experience additions on top of the 3.0 platform. All opt-in; the app still runs fully offline.

### Added

- **AI shop assistant** — an **Ask AI** button (dashboard) answers questions from your own shop data (revenue this/last month, outstanding, overdue, top materials, low stock). Grounded in a curated summary — it won't invent numbers. Uses your Anthropic key.
- **Customer portal accounts** — customers sign in at `cloud.khaytapp.com/portal` with their email + a one-time code (no password) and see **all** their orders, quotes, and deposits in one place.
- **Deposit on quote approval** — when publishing a quote, attach a deposit amount + a payment link from **any** provider; the customer pays from the portal and "paid" is confirmed via a secret-gated webhook (Khayt stays provider-agnostic).
- **Owner notifications** — the cloud emails you when a customer approves/declines a quote or pays a deposit.

### Changed

- **Your plan** is shown in the desktop Khayt Cloud card and the mobile app; cloud plans are operator-defined and **runtime-managed** (no redeploy to change).

## [3.0.0-beta.1] - 2026-06-20

**Khayt 3.0 — first beta.** Version realignment: the cloud platform shipped under the `2.8.0-beta.1…5` line is the **Khayt 3.0** initiative, so the version now reflects that. No features were removed; this is `2.8.0-beta.5` renamed to the 3.0 line, plus the items below. The app still runs fully offline — every 3.0 capability is opt-in.

### The 3.0 platform (recap)

- **Khayt Cloud** — opt-in, end-to-end-encrypted sync: email+password accounts, multi-device, background auto-sync, password reset + email verification. The server only ever stores ciphertext.
- **Customer portal** — public, owner-curated order-status links and quote approve/decline (an approved quote advances the order). Auto-refreshes on status change.
- **AI assist** — quote-from-description, AI-drafted customer messages, and consumption-aware reorder suggestions (your own Anthropic key).
- **Remote mobile** — a PWA at `cloud.khaytapp.com/m`: read your shop and advance order status from your phone, decrypted in the browser, installable + offline + Arabic/RTL.
- **Billing (optional)** — a provider-agnostic plan/entitlement system: define plans + limits in config; wire any payment provider via one normalized webhook. Your plan shows in the app and the PWA.

### Added (since 2.8.0-beta.5)

- **Your plan** is shown in the desktop Khayt Cloud card and the mobile PWA (silent when the server has billing disabled).

## [2.8.0-beta.5] - 2026-06-20

**Pre-release (beta)** — **Khayt on your phone.** A mobile web app (PWA), served by Khayt Cloud, lets you check your shop anywhere — fully end-to-end encrypted.

### Added

- **Remote mobile (PWA)** — open `cloud.khaytapp.com/m` on your phone, log in, and unlock with your sync passphrase to see a read-only **Dashboard** (active orders, open quotes, low stock) and **Orders** list, plus **advance an order's status** from your phone. Everything is decrypted **in the browser** (the server only ever holds ciphertext); the passphrase never leaves your device. Installable, works offline (app shell), Arabic/RTL, and auto-locks when idle.

### Internal

- Browser-portable E2E crypto verified byte-compatible with the desktop: WebCrypto AES-256-GCM (`lib/sync-crypto-web.js`) + a pure-JS scrypt (`lib/scrypt-js.js`, matches Node incl. N=32768). The PWA + serving live in the cloud repo.

## [2.8.0-beta.4] - 2026-06-20

**Pre-release (beta)** — follow-up to beta.3: smarter restocking and a self-maintaining customer portal.

### Added

- **Reorder suggestions** — beyond the low-stock badge: the dashboard low-stock card now opens a consumption-aware list that estimates each spool's usage from the last 30 days of completed orders, projects **days until empty**, and suggests a **reorder quantity** to cover the next ~45 days. **Copy list** / **Share WhatsApp** turns it into a supplier-ready order.

### Changed

- **Customer portal links stay current** — a published order/quote status link now **auto-refreshes when the order's status changes** (no manual re-publish). An approved quote that advances to Pending updates the public page automatically.

## [2.8.0-beta.3] - 2026-06-19

**Pre-release (beta)** — the 3.0 platform comes alive: **Khayt Cloud** (opt-in, end-to-end-encrypted sync) goes from dormant foundation to a working multi-device service, plus a **customer portal** and **AI-drafted customer messages**. Everything is opt-in — with cloud off, the app behaves exactly as before and runs fully offline.

### Added

- **Khayt Cloud — opt-in E2E sync.** Sign up with an email + password and sync your shop across devices, end-to-end encrypted: the server only ever stores ciphertext (it can't read your data). Two independent secrets — an **account password** (sign-in, resettable) and a **sync passphrase** (encryption, never uploaded; backed by a one-time recovery key). Settings → Khayt Cloud.
  - **Multi-device** — log in on another device and pull your data; the encrypted keyset is delivered on login and unlocked locally with your passphrase.
  - **Auto-sync on save** — changes sync in the background (debounced) with automatic conflict resolution (last-write-wins by revision, append-only logs preserved, deletes honored). Manual **Sync now** / **Restore from cloud** also available.
  - **Account recovery** — **password reset** and **email verification** via an emailed code.
- **Customer portal.** Publish a public, owner-curated status link for an order (`/p/…`) that works anywhere — shows only what you choose (shop, order #, status, due date). For quotes, the customer can **Approve / Decline** from the link, and an approved quote advances the order to Pending. Share via QR / Copy / WhatsApp.
- **AI message drafting (BYO key).** A new **✨ Draft message (AI)** order action drafts a short, localized customer message — status update, ready-for-pickup, quote follow-up, payment reminder, or a custom note — from the order's facts. You edit before sending (Copy / WhatsApp / Email). Uses your own Anthropic key; never invents prices or dates.

### Internal

- Cloud backend (separate repo) with per-IP rate limiting, per-shop storage caps, admin usage stats, and CI (Node tests + PHP lint); runs on managed PHP/MySQL hosting with no process to babysit.
- Test suite 527 → 549 desktop tests; cloud backend 15 tests.

## [2.8.0-beta.2] - 2026-06-19

**Pre-release (beta)** — the first 2.8 desktop feature drop: AI-assisted quoting, recurring maintenance, team roles, accounting export, print-farm scheduling, and more. The 3.0 platform foundations are present but dormant (opt-in, no behavior change when off).

### Added

- **AI quote (BYO key)** — describe a job in plain language and the assistant fills the cost calculator (print time, weight, material); the existing calculator still computes the price. Opt-in, off by default, uses your own Anthropic API key (stored encrypted, redacted from exports), and falls back to the manual form on any error. *Set up via the "🤖 AI quote" button by the calculator.*
- **Maintenance scheduler** — recurring, hours- or date-based preventive-maintenance tasks per machine, with due/overdue reminders in notifications and mark-done logging.
- **Team roles (RBAC)** — operators get a structured access level (Owner / Manager / Operator / Viewer); tab visibility follows a permission matrix. Backward compatible with the existing operator lock; legacy roles map automatically.
- **Accounting export** — export invoices and expenses to CSV (generic / QuickBooks / Xero / Zoho), VAT-aware and multi-currency, from the analytics toolbar.
- **Print-farm scheduling** — an assistive "Suggest assignments" action proposes which printer prints which job (by material, capability, deadline, and load); you review and apply.
- **Recurring-order reminders** — robust due-date detection for recurring customers surfaces as queue reminders.
- **Loyalty points** — a per-client points balance (earned on completed orders) shown on the client card.

### Fixed

- **G-code parsing** — print time and filament weight are now read from the file **footer** too (PrusaSlicer / SuperSlicer / OrcaSlicer write their summary there), so auto-fill works for the common slicers; filament type is also detected.

### Internal

- 3.0 platform foundations (all opt-in, no behavior change when off): local sync engine with change-tracking + deltas, end-to-end sync crypto, and the cloud sync-protocol client. A jsdom render-path test harness and 8 feature-core libraries. Test suite 288 → 527.

## [2.8.0-beta.1] - 2026-06-18

**Pre-release (beta)** — opens the 2.8 line over 2.7.0. The desktop app is functionally **unchanged** from `2.7.0`; this cycle's work is the iOS companion and internal test infrastructure, so the desktop build here is a checkpoint rather than a feature drop.

### Added

- **iOS Companion v2** ([`ios/`](./ios/)) — native SwiftUI redesign plus: live printer monitoring (progress / temps), clients with history, walk-in intake triage, in-app order creation and machine assignment, inventory edit/delete, and a Home Screen queue widget. LAN-only; the desktop app remains the source of truth. (Companion ships via Xcode, not the desktop release artifacts.)

### Changed

- **Tests** — added a jsdom render-path harness (`test/helpers/dom.js`) that loads the real `renderer/index.html`, so DOM-rendering fixes get real regression coverage instead of throwaway scripts. Locks in the 2.7 invoicing/analytics render-path fixes; suite now 293 tests.

## [2.7.0] - 2026-06-18

Graduates the 2.7.0 beta line (`v2.7.0-beta.1` → `beta.3`) to a stable release over `2.6.0`. A correctness/quality pass across inventory, invoicing, the production queue, analytics, settings, and localization. Highlights, consolidated from the per-prerelease sections below:

### Fixed

- **Filament accounting** — corrected spool reservation / over-commit (it was inert for normal parts), double-counted split prints, lost partial shortfalls, valuation that overstated partly-used spools, and a "NaN d" forecast.
- **Invoicing** — milestone invoices no longer re-bill the full shipping / rush / extras on each milestone.
- **Production queue** — a requeued card no longer jumps the queue after a column move; a paused print no longer shows a false "Overdue".
- **Order status** — reopening a completed order resets its completion state; completing directly from on-hold clears the hold.
- **Analytics** — quote conversion rate can no longer exceed 100%; no `-Infinity%` margins; SLA on-time uses local dates; client-LTV ranks by actual time.
- **Settings** — nested config (BNPL/email/ZATCA/LAN) deep-merges, so a saved partial value keeps its defaults.

### Changed

- **Localization** — German, Spanish, French, Japanese, and Chinese brought to full key parity with English (previously English-only on newer surfaces), then reviewed for terminology consistency. Dead "orphan" keys removed.

### Security

- **`/api/survey`** is now per-IP rate-limited, and LAN **CORS** no longer reflects arbitrary origins on PIN-gated routes (limited to loopback / LAN).

## [2.7.0-beta.3] - 2026-06-18

**Pre-release (beta)** — accounting/inventory/UI correctness + CORS hardening, on top of 2.7.0-beta.2.

### Fixed

- **Inventory** — valuation no longer overstates the value of partly-used spools that lack a recorded original weight (M3); the days-remaining forecast no longer renders "NaN" for non-numeric weights (M8).
- **Invoicing** — milestone invoices no longer re-bill the full shipping / rush / extras / discount on top of each milestone amount (M1).
- **Settings** — nested config (BNPL, email, ZATCA, LAN, …) now deep-merges, so a saved partial value (e.g. one BNPL provider's key) keeps the sibling defaults instead of dropping them (M2).
- **Production queue** — a manually-reordered card no longer jumps the queue after moving to another column (queue order is now column-scoped, M6); a paused print's estimated-completion badge no longer shows "Overdue" while paused (M7).

### Security

- **LAN CORS** — PIN-gated routes no longer reflect an arbitrary `http://` Origin; the reflected origin is limited to loopback / LAN hosts.

### Changed

- **Localization** — German, Spanish, French, Japanese, and Chinese are at full key parity with English (removed dead "orphan" keys left over from past renames).

## [2.7.0-beta.2] - 2026-06-18

**Pre-release (beta)** — correctness fixes, on top of 2.7.0-beta.1.

### Fixed

- **Order status transitions** — reopening a completed order (e.g. dragging it back for a reprint) now resets its completion state, so the print timer restarts fresh and the reprint re-deducts filament; completing directly from on-hold now clears the hold flags.
- **Analytics** — the quote conversion rate no longer exceeds 100% (measured within the created cohort); product margin no longer shows `-Infinity%` for zero-revenue jobs; SLA on-time/late uses local dates (no day-boundary flips); client-LTV "last order" ranks by actual time rather than a mixed string compare.

### Security

- **`/api/survey`** is now per-IP rate-limited — it was the only store-mutating public LAN route without a throttle (token-gated only).

## [2.7.0-beta.1] - 2026-06-18

**Pre-release (beta)** — first 2.7 beta, on top of stable 2.6.0.

### Fixed

- **Filament accounting (inventory)** — three deduction bugs corrected:
  - the over-commit / reservation check keyed on the optional per-part spool and so was inert for normal parts (which carry only a material) — it now mirrors the actual deduction, so over-commit warnings and reserved-grams reflect real demand;
  - split prints recorded via the spool-switch flow no longer double-count filament (completion deducts only the remainder);
  - a partial shortfall on the chosen spool is now drawn from other same-material spools (location-preferred) instead of being silently lost.

### Changed

- **Localization** — German, Spanish, French, Japanese, and Chinese reach full key parity with English: 296 previously-English-only strings (the Workbench/Command/Vivid/Cockpit/Atlas dashboards, the updater dialog, quote follow-up, per-location inventory + transfers, electricity/exchange-rate helpers, label printing) are now translated. These are AI-generated and pending a native-speaker review pass.

## [2.6.0] - 2026-06-18

Graduates the 2.6.0 beta line (`v2.6.0-beta.1` → `beta.8`) to a stable release over `2.5.0`. Highlights, consolidated from the per-prerelease sections below:

### Added

- **Redesigned themes** — three new light-default, native-feel designs: **Workbench** (the new default), **Command**, and **Vivid**, replacing the previous default. The earlier themes remain selectable as legacy options.
- **Printer alerting** — notifications when a printer goes into error, offline, or stall, over Telegram / webhook / email, with per-printer cooldowns.
- **Per-location inventory** — assign spools to a branch; inventory, low-stock/reorder, valuation, and auto-deduction scope to the active location. Stock transfers and 62 mm spool QR labels.
- **Live currency rates** and **per-country electricity rates** in the calculator.
- **Quote follow-up automation** — opt-in expiring-quote nudges.

### Changed

- **Salted PBKDF2 PIN hashing** — operator/admin PINs and recovery codes now use salted PBKDF2-SHA256 (existing PINs upgrade transparently).

### Fixed

- **ZATCA Phase-2 signing** — invoice signatures are no longer double-hashed (would have been rejected by ZATCA).
- **Invoicing** — fixed a crash that broke all invoice rendering, and corrected credit-note accounting (was double-counted in balances/payment status).
- **Data safety** — a malformed collection no longer discards the whole store on load; saves no longer fail for shops with a stored ZATCA/BNPL/Telegram/LAN secret.
- **Localization** — restored dropped placeholders across Arabic confirm dialogs/toasts/badges and the de/es/fr/zh low-stock alert; RTL fixes.

## [2.6.0-beta.8] - 2026-06-17

**Pre-release (beta)** — QA pass: language review, security + bug scan, UI review.

### Fixed

- **Invoices failed to render** — a missing variable (`subtotalShown`) threw on every invoice generate/print/PDF/WhatsApp path. (regression)
- **Credit notes were double-counted** — a credit note reduced `paidAmount` *and* was subtracted again from the balance, so refunded/credited orders showed the wrong outstanding amount and payment status. Credit now reduces the amount **due** exactly once, consistently across balances, statements, and payment status.
- **Saving could fail (data loss) for some shops** — the secret-merge step crashed when a ZATCA / BNPL / Telegram / LAN secret was stored on disk but the incoming snapshot had no `settings`, so that save was dropped.
- **Analytics could show "NaN"** print-hours when an order lacked a print time.
- **Localization** — restored dropped `{placeholders}` in **28 Arabic** strings (credit-limit and over-commit confirm dialogs, capacity/tier/progress toasts and badges) that were showing without their amounts/dates/counts; restored the material + quantity in the **German / Spanish / French / Chinese** low-stock alert; fixed the Arabic "view queue" / "go" arrows to point the right way in RTL.
- **Command theme** — the status-bar clock now follows the app language instead of always rendering Western digits.

### Added

- CI guard (`locale-parity` test) that fails if an Arabic string drops an English `{placeholder}`.

## [2.6.0-beta.7] - 2026-06-17

**Pre-release (beta)** — theme-picker polish + documentation refresh, on top of 2.6.0-beta.6.

### Changed

- **Theme-picker previews** — Settings → Preferences → Design now shows real preview thumbnails for the **Workbench**, **Command**, and **Vivid** themes (they previously shipped as placeholders).
- Refreshed the README screenshots and theme documentation to the current Workbench design, and removed unused legacy screenshot galleries.

## [2.6.0-beta.6] - 2026-06-17

**Pre-release (beta)** — two features off the backlog plus repo cleanup, on top of 2.6.0-beta.5.

### Added

- **Printer alerting** — fires a notification when a printer goes into **error**, **offline** (after repeated failed polls), or **stall** (progress frozen mid-print), through the existing Telegram / webhook / email channels, with per-printer cooldowns. Toggle each under Settings → Telegram.
- **Per-location inventory + spool QR labels** — spools can be assigned to a branch; the inventory list, low-stock/reorder alerts, valuation, and auto-deduction scope to the active location (legacy/unassigned stock stays visible). Transfer stock between branches, and print a 62 mm QR label for a spool.

### Changed

- Repository cleanup: pruned ~60 merged/closed branches and removed leftover dev scripts.

## [2.6.0-beta.5] - 2026-06-17

**Pre-release (beta)** — security hardening, on top of 2.6.0-beta.4.

### Security

- **Salted PIN hashing** — operator/admin PINs and recovery codes are now hashed with salted PBKDF2-SHA256 instead of unsalted SHA-256, so a leaked store can't be brute-forced offline as easily. Existing PINs keep working (verified transparently) and upgrade to the salted format when next set.

## [2.6.0-beta.4] - 2026-06-17

**Pre-release (beta)** — a comprehensive security/correctness audit pass plus two new features, on top of 2.6.0-beta.3.

### Added

- **Live currency rates** — Settings → Payments → Exchange rates has a **Fetch live rates** button that pulls current FX from a free no-key service (with a "last updated" stamp); manual edits still work.
- **Electricity rate by location** — the Calculator's Electricity field has a **📍 Auto** button that asks for your country and fills a typical commercial rate, converting into your base currency via your saved exchange rates.

### Fixed

- **ZATCA Phase-2 signing (critical)** — invoice signatures were double-hashed and would have been rejected by ZATCA; they now sign `SHA256(canonical)` so the signature matches the reported invoice hash.
- **Data safety** — a single malformed collection no longer discards the whole store on load (valid data is salvaged); fully-credited orders no longer show as outstanding.
- **Invoicing** — invoice summary now reconciles (Subtotal + Rush + Shipping = Total, VAT shown as included); client statement is base-currency consistent and no longer double-counts gift-card-settled orders.
- **Calculator** — live price preview matches the committed cart cost (includes extras + packaging).
- **Inventory** — spool reservation, over-commit, and forecast now match actual deduction (support weight × quantity).
- **Orders** — order-completion webhooks + post-sale survey token now fire (were unreachable); priority badge shows the level, not "true"; assorted crash guards (due-date suggest, invoice timestamps).
- **macOS window controls** — the new themes' title strip is now macOS-only, so it doesn't add an empty strip on Windows/Linux.

### Security

- XSS escaping in the Command dashboard; `save-html` forced to a safe extension (RCE guard); CSS-injection sinks use a color sanitizer; SMTP refuses plaintext credential auth; webhook timeout + DNS-rebinding recheck; printer-poll host allowlist tightened; `export-pdf` write confinement; navigation locked to the app; tunnel refuses weak PINs; Salla/Zid webhook replay protection; webhook token header-only.

### Accessibility

- Vivid colored band contrast (dark scrim); nav group-label contrast and keyboard focus rings; status-chip contrast (light + dark); Command inspector exposed to screen readers when open; monochrome kanban/rail icons.

## [2.6.0-beta.3] - 2026-06-17

**Pre-release (beta)** — visual QA pass over the new design system, on top of 2.6.0-beta.2.

### Fixed

- **macOS window controls** — Workbench / Command / Vivid hid the title bar, so the traffic-light buttons overlapped the sidebar brand / icon rail. Restored a slim, draggable title strip that reserves room for them.
- **Workbench top bar** — the language/location selects could drop onto a second row; the bar is now a single non-wrapping row (the search shrinks first), and "All locations" is no longer cramped.
- **Command** — the open-tab strip no longer overlaps the ⌘K search, and is hidden when only one screen is open (it previously just echoed the page title).
- **Vivid** — white top-band controls stay legible on the lighter per-module hues (Orders / Analytics); the location/language selects now match the band's glass treatment.
- **All new themes** — the notification count badge is anchored to the bell instead of drifting to the toolbar edge; dark-mode colour swatches (filament dot, spool card) get a faint ring so near-black fills stay visible.

## [2.6.0-beta.2] - 2026-06-17

**Pre-release (beta)** — a new default design system plus UI fixes, on top of 2.6.0-beta.1.

### Added

- **New design system — Workbench / Command / Vivid** — three light-default, native-app designs replacing the previous theme line. **Workbench is the new default.** The seven legacy designs (Studio, Ledger, Console, Atelier, Vitrine, Cockpit, Atlas) are hidden from the picker (code retained for now), and existing installs auto-migrate to the nearest new design (studio/ledger/console → Workbench, cockpit/atlas → Command, vitrine/atelier → Vivid).

### Fixed

- **Top bar** — the language/location dropdown text was vertically clipped; the new shells also showed a duplicate search control and could wrap to multiple rows. Now a single, slim, one-row bar.
- **Calculator** — the primary button is correctly labelled “Create order & send to queue” (was mislabelled “Save quote”) and confirms before creating an order from a non-empty build.
- **Clients** — sortable columns and a display cap on large lists.

### Changed

- Form grids collapse to a single column below 600px, so inputs aren’t squeezed in narrow windows/modals.

## [2.6.0-beta.1] - 2026-06-16

**Pre-release (beta)** — UI usability & accessibility, the update-review modal, the iOS companion, print-farm multi-site, and new LAN write endpoints, on top of stable **2.5.0**.

### Added

- **iOS Companion app** — native SwiftUI app over the desktop LAN API: home quick actions, queue/kanban strip, orders (active filters + history), order/spool detail, inventory search + low-stock, English/Arabic + RTL, connection banner, local notifications, home-screen widget, Siri shortcuts. NFC tag **read**, and NFC tag **write** with an OpenTag3D / OpenPrintTag / OpenSpool standard picker (default OpenTag3D for desktop-reader compatibility).
- **Print farm — sites & location filter** — top-bar location filter scopes dashboard KPIs, production queue, machine queues, and orders log; **Sites overview** on the dashboard (Professional, 2+ locations); wizard **Print farm** preset (Professional mode, default WIP limits, second-site stub).
- **LAN write endpoints** — `GET`/`PATCH /api/waiting-list`, `GET /api/clients`, `PATCH`/`DELETE /api/inventory/:id`, `machineId` on `PATCH /api/orders/:id`, `POST /api/orders`, and live telemetry — all with field allowlists, prototype-safe JSON parsing, and tunnel-aware rate limiting.
- **Quote follow-up** — dashboard "Expiring quotes" card with one-click WhatsApp/email follow-up, plus an opt-in auto-nudge for quotes nearing expiry (off by default).
- **Global search** — fuzzy/subsequence matching plus printers, suppliers, and expenses results; main-nav arrow-key (and Home/End) tab switching.
- **Update changelog screen** — manual “Check for updates” and the automatic launch check show release notes in a review modal before download/install (keeps the pre-update backup and hardened install flow).

### Fixed

- **Setup wizard** — selecting **Print farm** / **Company B2B** now correctly saves Professional mode (was always saved as Simple); **Back** buttons no longer skip the security step.
- **Modals** — focus trap keeps Tab inside dialogs; focus restores to the previous element on close.
- **Settings save** — post-process presets are no longer wiped when saving other settings panels.
- **Global search** — client and product results navigate to the correct record; keyboard ↑/↓ + Enter works.
- **Help shortcut** — `?` opens help again (Shift was incorrectly blocked).
- **Delete safety** — locations and operators require confirmation before deletion.
- **Notifications** — bell exposes `aria-expanded`; toast container announces to screen readers.
- **Feedback** — toast when the email app cannot be opened (suggests the GitHub Issue button).
- **QC-fail analytics** — waste cost no longer divides by a depleted spool's zero weight (was writing `Infinity`/`NaN` into waste/profit totals).
- **Recurring expenses** — the next-due date stays on its anchor day instead of drifting each cycle.
- **ZATCA Phase-2 QR** — invoice fields over 255 bytes now encode a valid TLV length (no malformed signed QR).
- **Inventory low-stock** — one consistent threshold check so the banner and row badge agree; multi-part completion now shows a single summary toast so the low-stock warning isn't dropped by the toast cap.

### Changed

- **Preferences** — language and theme apply immediately when changed.
- **Settings on narrow windows** — section nav stacks/wraps on small screens.
- **Undo** on order status moves and on spool / client / waiting-list deletes; wide tables scroll horizontally instead of clipping columns.
- Removed dead wizard code/markup, 17 unused legacy locale keys, and 57 orphaned flat keys; new `upd.*`, `search.*`, `farm.*`, `loc.*`, and iOS/LAN strings added in English and Arabic; a `locale-parity` test now gates `ar ⊇ en`.

### Security

- **NFC tag parsing** — CBOR/NDEF decoders bound all counts/lengths, cap recursion, and limit paste size, so a malformed tag dump can't hang the app.
- **LAN tunnel** — added a global failed-auth throttle backstop (per-IP lockout can be bypassed via spoofed `X-Forwarded-For`) and a weak-PIN warning when exposing over a tunnel.
- **Dependencies** — pinned `form-data ^4.0.6` (GHSA-hmw2-7cc7-3qxx).

## [2.5.0] - 2026-06-16

Graduates the Khayt-4 beta line (`v2.4.0-beta.1` → `beta.4`) to a stable release: seven selectable design themes, the Settings redesign, the LAN/security hardening pass, and the beta→stable updater. Released as **2.5.0** (minor) over stable `2.3.3` — the `2.4.0` number was only ever published as pre-releases. Per-prerelease detail is consolidated in the sections below.

### Fixed

- **Beta → stable graduation (updater)** — `isVersionNewer` is now prerelease-aware: a stable release outranks its own prerelease (`2.4.0 > 2.4.0-beta.4 > 2.4.0-beta.1`, and `2.4.0-rc.1 > 2.4.0-beta.9`). Previously the prerelease suffix was stripped before comparison, so a final `2.4.0` would report "up to date" to every `2.4.0-beta.x` tester and never offer the graduation build.

### Added

- **Opt-in beta updates** — `applyUpdateOptions` / `hub:set-update-options` and an `allowBeta` flag on `interpretUpdateCheckResult`; prerelease offers are hidden from stable installs unless beta is opted in (Settings → Data & Locale → Include beta pre-releases).

## [2.4.0-beta.4] - 2026-06-11

**Pre-release (beta)** — Settings redesign.

### Changed

- **Settings navigation** — the in-Settings section list is now a horizontal tab strip across the top (instead of a second left sidebar), with the active section marked by an accent underline and a thin General/Advanced divider.
- **Settings layout** — every section is now a stack of themed cards (grouped sub-sections) with a readable, centered content width, replacing the full-width forms. All 11 sections (Business, Preferences, Inventory, Invoice & Tax, Payments, Printers, Online, Operations, Automation, Access, Data & Locale) follow the same pattern.
- New section/header strings added across all 7 locales.

## [2.4.0-beta.3] - 2026-06-11

**Pre-release (beta)** — Review follow-up: updater channel fixes, LAN hardening, SMTP injection fix, theme polish.

### Fixed

- **Beta channel applied at boot** — the saved *Include beta pre-releases* preference is now pushed to the updater during startup, so opted-in testers are offered beta builds on the automatic launch check (previously only synced after opening Settings).
- **Beta → stable graduation** — `isVersionNewer` is now prerelease-aware: a stable release outranks its own prerelease (`2.4.0 > 2.4.0-beta.2`), so beta testers are correctly offered the final release instead of being told they're up to date.
- **LAN no-PIN hang** — owner-data GET endpoints (`/api/orders`, `/api/queue`, `/api/machines`, `/api/inventory`, `/`) return `401` instead of leaving the socket open when no LAN PIN is configured.
- **Theme shell teardown** — ledger/console page-header is reclaimed by id (matching mount) on theme switch, removing a fragile class-only lookup.

### Security

- **SMTP header/command injection** — custom-SMTP `From`/`To`/`Subject` are stripped of CR/LF and control chars, and message bodies are dot-stuffed (RFC 5321), preventing injection via customer-influenced recipient/subject or body content.
- **Tunnel rate-limiting** — brute-force lockouts and intake limits derive the client IP from the tunnel's `X-Forwarded-For` first hop when a remote tunnel is active, so per-client limits no longer collapse into one shared bucket.
- **Survey page hardening** — inline-script JSON on the customer status page is `</script>`-safe (escapes `<`, `>`, `&`), closing a latent stored-XSS sink.

### Accessibility

- **Atlas nav** — active navigation item exposes `aria-current="page"` for screen readers.

## [2.4.0-beta.2] - 2026-06-05

**Pre-release (beta)** — Security hardening pass + stable **v2.3.3** updater parity.

### Added

- **Opt-in beta updates** — same as stable v2.3.3: Settings → Data & Locale → **Include beta pre-releases** (off by default).

### Security

- **Printer webhook lockout** — failed auth uses isolated `printer` channel key (no longer locks owner PIN).
- **LAN spool POST** — field allowlist on `/api/inventory/spools`; arbitrary keys dropped.
- **Intake reference links** — `http`/`https` only at ingestion (`javascript:` / `data:` rejected).
- **LAN HTML pages** — `CSP`, `X-Frame-Options`, `nosniff`, `Referrer-Policy` on customer-facing HTML.
- **Update flush** — `hub:install-update` normalizes store snapshot before disk write.
- **Confirm modal XSS** — `promptTypeConfirmModal` always escapes message text.
- **`safeJsonParse`** — strips `prototype` keys (defense in depth).

### Fixed

- **LAN IDs** — spool/intake/Salla/Zid IDs include random suffix (collision-safe).
- **PWA manifest** — `shopName` JSON escaping fixed (no double-escaped quotes).

## [2.4.0-beta.1] - 2026-06-05

**Pre-release (beta)** — Khayt-4 design themes ship beside stable **v2.3.2**. Install from [GitHub Releases → Pre-releases](https://github.com/khaytapp/Khayt/releases). Stable installs do not auto-update to beta; see [docs/BETA-RELEASE.md](./docs/BETA-RELEASE.md).

### Added

- **Design themes** — Settings → Preferences: **Studio** (sidebar) or **Workshop Ledger** (masthead + horizontal tabs); per-design accents from the Khayt-3 handoff. Reserved slots: **Blueprint**, **Atlas**.
- **Theme template system** — `renderer/themes/_template/` + `themes/custom/` registry for community themes; see [docs/THEMES.md](./docs/THEMES.md).
- **Local UI fonts** — Archivo, Hanken Grotesk, IBM Plex Mono/Arabic vendored under `renderer/fonts/` (CSP-safe, no Google Fonts).
- **Theme previews** — Visual theme picker with screenshots in Settings and setup wizard (`renderer/themes/previews/`, `npm run capture:theme-previews`).
- **Handoff screen parity** — Studio screen enhancements (KPI grid, queue filters, calculator breakdown, inventory stats, client cards) now apply to Workshop Ledger via shared `khayt-handoff` layer.
- **Handoff analytics** — Analytics tab KPI row, machine P&L bars, production heatmap, and top-clients table for Studio and Ledger themes.
- **Control Room theme** — Khayt-4 direction C: graphite console shell with command bar, 64px code rail (DSH/QUE/…), `//` page headers, and status bar; four signal accents (phosphor, amber, cyan, monochrome).
- **Atelier theme** — Khayt-4 direction D: cream gallery canvas, floating sidebar, serif display headers, pill controls; clay/sage/sea/violet accents.
- **Vitrine theme** — Khayt-4 direction E: ambient glass backdrop, frosted sidebar, glowing accents; aurora/iris/orchid/sunset presets.
- **Cockpit theme** — Khayt-4 direction F: 74px icon rail, ops dashboard (fleet + day timeline + attention feed), chunky poster chrome; electric/violet/emerald/flare accents.
- **Spectrum skins** — Cockpit sub-setting: Poster (default), Lumen, Draft, Clay via `data-skin`.
- **Atlas theme** — Khayt-4 Frontier direction H: spatial floor map with live machine stations, zone layout, and inspector panel; phosphor/ember/iris/signal accents.
- **Frontier reserved** — Pulse (command-first) and Stream (conversational ops) registered as coming-soon themes.
- **Khayt-4 QA** — `test/themes-qa.test.js` (previews, locale keys, shells); `npm run test:e2e:themes` (seven-theme nav + Atlas RTL); Arabic theme strings in `ar.js`.
- **Phase 1 complete** — Studio `ds.css` scoped to prevent Ledger bleed; app-only tabs and Settings use handoff polish (SVG nav icons, themed toolbars/tables).

### Fixed

- **Workshop Ledger tabs** — Studio sidebar CSS no longer leaks into Ledger (horizontal tab strip, active underline, Settings tab); grid layout and collapsed-sidebar state fixed for Ledger shell.

### Security

- **Tunnel rate-limiting** — Brute-force lockouts and intake rate limits now derive the client IP from the tunnel's `X-Forwarded-For` first hop when a remote tunnel is active, so per-client limits no longer collapse into one shared bucket (a single client could otherwise lock out everyone).
- **Webhook lockout isolation** — Printer-webhook auth failures use a dedicated lockout channel; a misconfigured printer spamming bad tokens can no longer lock the owner out of PIN/queue access (and vice versa).
- **Survey page hardening** — Inline-script JSON on the customer status page is now `</script>`-safe (escapes `<`, `>`, `&`), closing a latent stored-XSS sink.
- **Dead code removal** — Removed the unused intake-PIN page that implied the public intake form was PIN-gated.
- **Calendar feed** — `/calendar.ics` requires `?token=` (auto-generated `calendarToken`); iCal export copies the subscription link.
- **Intake abuse** — Rate limit on new intake session grants (40/hour per IP).
- **URL sinks** — Supplier website links and product/portfolio thumbnails sanitized via `safeHttpUrl` / `safeImageSrc`.
- **Keychain warning** — Boot toast when OS secure storage is unavailable.

### Fixed

- **LAN no-PIN hang** — Owner-data GET endpoints (`/api/orders`, `/api/queue`, `/api/machines`, `/api/inventory`, `/`) now return `401` instead of leaving the socket open when no LAN PIN is configured.
- **Fonts / CSP** — The runtime CSP header now matches the renderer's meta CSP, so the bundled web fonts (including IBM Plex Sans Arabic for RTL) load instead of silently falling back to system fonts.
- **Survey export** — Interactive HTML pages keep their scripts; `JSON.parse` replaces missing `safeJsonParse` in exported surveys.
- **Start Tunnel** — Syncs LAN form before start; owner PIN resolved from disk (not blocked by masked UI state).
- **Tunnel restore** — `tunnelEnabled` restores tunnel after LAN server starts on boot.
- **LAN status UI** — Online/LAN panels reflect live server state via `getLanUrl()`, not just saved config.
- **Email / webhooks** — Failures surface warning toasts instead of failing silently.
- **Machine secrets** — Secret merge uses machine ID only (no array-index fallback).

### Security

- **Quote approval** — `GET /order/:id/quote` now requires a valid `?token=`; order IDs alone no longer expose quote details or mint approval tokens.
- **Printer secrets** — Mask `printerApi.accessCode` in renderer even when `apiKey` is absent.
- **LAN tunnel** — Stopping or restarting the LAN server now closes an active remote tunnel.

### Added

- **Security audit doc** — [docs/SECURITY-AUDIT.md](./docs/SECURITY-AUDIT.md) with findings, fixes, and open items.

### Fixed

- **Settings panel Save** — Buttons in Preferences, Stock, Invoice, Online, etc. now save via `saveSettingsFromPanel()`.
- **Settings save data loss** — `saveSettingsFromForm()` no longer drops `onlineEnabled`, app security, or quote numbering fields.

- **Platform decision doc** — [docs/PLATFORM-MIGRATION.md](./docs/PLATFORM-MIGRATION.md): stay on Electron; when/how to revisit Tauri or shared core (not Swift+C++ per OS).
- **Online option** — Settings and setup wizard toggle to enable customer quote requests via LAN intake link (`/intake`); panel on Job Intake with copy link; no Khayt cloud.
- **Online hub** — Settings panel lists intake, quote-approval, and tracking links (copy per order) when LAN server is running.
- **Intake → calculator** — Job Intake “Quote in calculator” pre-fills client, part name, and notes (creates client when needed).
- **Solo maker dashboard** — Simple mode shows a focused “Your shop today” row; farm-style KPI/machine load stays in Professional mode.

### Changed

- **Check for updates (source builds)** — Explains that new work is on `main` via `git pull`, not the DMG feed, while release hold is active.

- **Online settings discoverability** — Dedicated **Settings → Online** sidebar item (enable quote requests, intake link, LAN server); no longer buried at the bottom of Data & Locale.

### Fixed

- **Intake — no customer PIN** — `/intake` always opens the order form when the LAN server is running; the intake PIN gate is removed.
- **Intake QR opens form** — Scanning the LAN QR opens the customer order form directly (no PIN gate). QR always points to `/intake`. The full URL is shown in a box above the QR. Any phone browser hitting `/api/status` (including old QRs) is redirected to `/intake`; API clients use `/api/status?format=json`.
- **Intake PIN visible** — The customer intake PIN is now displayed in plain text with a Copy button in Settings → Online (and as a visible field in LAN settings) so the shop owner can share it with customers. Previously it was masked immediately after server start, making the intake form inaccessible. The PIN value is now returned from the `hub:start-lan-server` IPC response and kept readable in memory.
- **LAN QR target** — In Settings, the LAN QR now opens `/intake` when Online is enabled (phone-friendly) instead of raw `/api/status` JSON; `/api/status` remains fallback when Online is off.
- **QR codes** — Customer portal, quote approval, and exported quote PDFs now show a real QR image; `hub:generate-qr` returns a base64 data URL when `{ dataUrl: true }` is passed (all `<img src>` callsites), raw SVG otherwise.
- **LAN / Online access** — Starting the server with Online enabled (or “Listen on LAN”) now binds to all interfaces; prefers Wi‑Fi IP (192.168.x) over VPN; warns if still localhost-only.
- **Settings sidebar** — Business / Online / Data & Locale (and other sections) switch correctly again; `openSettingsSection` is exported from the shell module (clicks had been failing silently).
- **Store load on macOS** — Keychain explanation dialog used invalid Electron `showMessageBox` type (`information` → `info`); load no longer fails if the dialog errors.
- **Check for updates** — Returns a real status from the updater (dev/source builds, errors, and version numbers) instead of assuming “up to date” after a timeout when the check failed or the app was not packaged.

## [2.3.2] - 2026-06-04

### Fixed

- **Setup wizard** — No longer reopens on every launch when the shop already has data or wizard completion was not persisted (`firstRunDone` / `flushSave` on finish; one-time flag normalization after load).

## [2.3.1] - 2026-06-04

Stabilization patch after **v2.3.0** — bug fixes and dependency hygiene, no new features.

### Fixed

- **Portal QR / tracking links** — Customer portal modal and exported quote PDFs now include `?token=` (portal previously used `/order/:id/status` without a token and returned 403).
- **Operator PIN** — Flush store to disk before main-process PIN verify; avoid stale disk read; renderer fallback if operator missing on disk snapshot.
- **Recurring expenses** — `calcNextDueDate` uses UTC calendar dates so monthly advance is consistent across timezones (off-by-one day outside UTC).

### Changed

- Shared `buildLanOrderTrackingUrl` / `buildLanQuoteApprovalUrl` helpers for consistent LAN links.
- **npm audit** — `overrides` for `localtunnel` nested `axios`/`debug` and build `tmp` (**0** reported vulnerabilities in `npm audit`).
- **155** unit tests in `npm run check`.

## [2.3.0] - 2026-06-04

Stability and security release — consolidate scan passes 4–6 and release hardening. Treat this as the gate before new features.

### Security

- **LAN order tracking** — `GET /order/:id` and static `/status/*.html` require a valid `?token=` matching the order `trackingToken`; new orders get a token at creation; legacy orders receive tokens on load via `ensureOrderTrackingTokens()`.
- **Quote approval** — Per-order `quoteApprovalToken` closes IDOR on public approve routes.
- **Privileged IPC** — Global `hub:*` guard (`lib/ipc-guard.js`): only the main `BrowserWindow` may invoke IPC; legacy per-handler checks retained where needed.
- **Operator PIN** — Verified in the main process via `hub:verify-operator-pin` (timing-safe compare against on-disk store).
- **Legacy status pages** — On-disk HTML scrubbed at startup and when served over LAN (client row removed, scripts stripped).
- **Import / restore** — Full replace via `replaceStoreFromSnapshot()` (no merge-with-old-data on import).
- **Operator PIN pad** — Stacked overlay (does not destroy open modals); timing-safe PIN compare.
- **Status HTML** — Exported and auto-exported pages omit client name (privacy).
- Prior 2.2.4–2.2.7 fixes retained: LAN persistence, serialized saves, webhook redirect block, intake/session hardening, renderer timing-safe secrets, calendar PIN, Mailgun domain sanitize, clipboard/QR limits, inventory POST validation, full-wipe main-process confirm, modal overlay stacking, dead handler wiring.

### Fixed

- Currency labels refresh after settings save; kanban WIP badge; reorder PO modal class; photo upload error toasts; schedule RTL and pause i18n.

### Changed

- **153** unit tests in `npm run check`.

## [2.2.3] - 2026-06-04

### Fixed

- **Mac auto-update stuck on "Saving data…"** — update install no longer re-encrypts the full store twice; pre-update backup copies the on-disk store file instead of sending a huge JSON blob over IPC. Flush and backup steps time out gracefully and continue to install.

## [2.2.2] - 2026-06-04

### Fixed

- **Form modals** — Add client, add printer, and all `openFormModal` dialogs scroll on short screens (sticky header/footer).
- **Currency labels** — Calculator, dashboard, and expense units follow Settings currency instead of locale defaults; labels refresh after language change and wizard setup.
- **LAN quote approval** — Expired quotes can no longer be approved via POST; LAN quote page shows shop currency code.
- **Intake sessions** — Session cookies are bound to the client IP that created them.
- **Store save** — `hub:save-store` normalizes snapshots before writing (same validation as load).
- **Custom SMTP** — Blocks loopback and cloud metadata hosts to reduce SSRF risk (LAN mail relays still allowed).
- **Recovery code modal** and **operator PIN pad** — Scroll when content exceeds viewport.

### Security

- LAN API POST bodies use `safeJsonParse` instead of raw `JSON.parse`.
- Intake PIN generation uses `crypto.randomInt` instead of `Math.random`.
- Recovery code verification uses timing-safe hash comparison.

## [2.2.1] - 2026-05-30

### Added

- **Setup wizard** — language first; optional admin PIN with recovery code (copy/download); re-runs after data reset.
- **App security** — optional admin PIN + recovery code; gates reset and full wipe when enabled.
- **Full wipe** — deletes all local app data and restarts (Settings → Data).

### Changed

- Default theme for new installs is **light**.
- **Reset data** clears inventory completely (no starter spools) and re-opens the setup wizard.

## [2.2.0] - 2026-05-30

Four-bundle release: production shop, ZATCA compliance, LAN quote approval, and platform hardening. Completes [ROADMAP.md](./ROADMAP.md) 2.2.0 goals.

### Added

- **Production shop (Bundle A)** — gift card checkout in payment modal; WIP hard-limit setting; LAN printer polling on private-network hosts.
- **ZATCA & email (Bundle B)** — Phase 2 FATOORA auto-submit on invoice, submission audit log, manual retry, custom SMTP provider.
- **LAN quote approval (Bundle C)** — public `GET/POST /order/:id/quote` approval page; share approval link modal; static export with LAN QR; client-approval sync with invoice numbering and webhooks; post-delivery portal survey.
- **Platform hardening (Bundle D)** — expanded E2E critical flows (tab navigation, order lifecycle, boot/store/LAN PIN via `scripts/e2e/helpers.mjs`); `prestart` / `pretest:e2e` run `scripts/ensure-electron.js` with `npm run install:electron`; `scripts/list-stale-branches.mjs` for superseded PR branches; `npm run check` runs lint + unit tests.

### Fixed

- LAN printer polling now connects to RFC1918 hosts (`192.168.x.x`, `10.x`, `octopi.local`). Previously `isBlockedHost` blocked all private addresses.

## [2.1.2] - 2026-05-30

### Fixed

- Ship Claude-designed app icon assets on `main` (export PNGs + wired `icon.icns` / iconset). Previous releases used the programmatic `make_icon.py` art because only the wire script was merged, not the export files.
- macOS Dock / window icon: set `BrowserWindow.icon` and `app.dock.setIcon()` from `assets/icon_preview.png` in dev.

## [2.1.1] - 2026-05-30

### Fixed

- **Critical:** Export `importClientsCsv` globally so app boot completes — fixes blank dashboard and non-working Settings sidebar links (`wireEvents` aborted mid-setup during 2.1.0 modular split).

### Changed

- Settings → About credits AI-assisted development; production queue toolbar actions lay out horizontally again.
- Removed optional GitHub Sponsors URL field — sponsor button links to the official profile.
- Added missing inventory and queue locale strings; README updated for 2.1.x.
- E2E smoke test now asserts dashboard render and Settings nav.

## [2.1.0] - 2026-05-30

Significant release: modular renderer and main process, store validation, expanded test suite, and CSP hardening. Completes [ROADMAP.md](./ROADMAP.md) 2.1.0 goals.

### Added

- Versioning policy (`VERSIONING.md`), release checklist, and `npm run version:*` helpers.
- Maintainer guide (`CONTRIBUTING.md`) and engineering roadmap (`ROADMAP.md`).
- `npm run lint`, `npm run check`, and `npm test` (120 unit tests).
- `npm run test:e2e` — Electron smoke (launch, store round-trip, LAN PIN gate).
- `npm run i18n:extract` — locale file extraction; per-language bundles in `renderer/locales/*.js`.
- `lib/store-io.js`, `lib/updater.js`, `lib/lan-server.js`, `lib/zatca-crypto.js` — split from `main.js`.
- `renderer/store-validate.js` — snapshot shape checks and normalization on load.
- Renderer modules split from `app.js`: `app-state`, `shell`, `app-helpers`, `app-boot`, `app-exports`, `wire-events`, `build`, `inventory`, `machines`, `clients`, `expenses`, `waste`, `views`, `notifications`, `ops-locations`, `integrations`, `operations-extras`, `kanban`, `invoicing`, `logs`, `settings`, `order-flows`, `waiting-list`, `dashboard`, `analytics`, and related helpers (`format`, `util`, `currency`, `calculator-cost`).
- Unit tests for ZATCA ASN.1, store I/O, store validation, LAN server helpers, invoicing TLV/XML, and renderer pure-logic helpers.

### Changed

- `renderer/app.js` is a thin entry shell (~7 lines); feature logic lives in `renderer/*.js`.
- Log operator filter and pagination state live in `app-state.js` with other log UI globals.
- `safeJsonParse`, `isBlockedHost`, and ZATCA ASN.1 helpers moved from `main.js` into `lib/` for reuse and testing.

### Security

- Electron CSP: drop `script-src 'unsafe-inline'` (renderer uses `data-act`; exported HTML may still use inline scripts).
- LAN tunnel: require explicit risk acknowledgement before starting `localtunnel`.

## [2.0.16] - 2026-05-30

Patch line preceding 2.1.0. See [GitHub Releases](https://github.com/khaytapp/Khayt/releases) for prior `2.0.x` notes.
