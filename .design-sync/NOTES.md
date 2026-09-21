# design-sync notes — Khayt

## What is being synced, and what it is not

Khayt's UI lives in two places and **neither of them is a component library**:

- the **Mac app** (`mac/KhaytCore/Sources/KhaytApp/`), SwiftUI — this is the
  product, and it is what the design system mirrors;
- the **Electron renderer** (`renderer/`), which builds HTML strings inside
  global functions and exports nothing.

Claude Design renders React in a browser, so neither can be synced as-is. A
previous run proved that the hard way: it pointed the converter at the repo,
discovered **zero components**, and uploaded a bundle with an empty
`renderHashes` — the shell that was still sitting in the project when this run
adopted it.

So `design-system/` was written: a small React package that mirrors the Mac
app's vocabulary. **It is new code, not something Khayt ships.** What is NOT
invented is the look — every colour, type step and the card geometry is read
out of the Swift.

## The tokens are generated. Do not hand-edit them.

`.design-sync/extract-tokens.mjs` reads `Palette.swift`, `Surface.swift`,
`TypeScale.swift` and `Motion.swift` (see "Motion is extracted too" below) and
writes `design-system/src/tokens/khayt.css`. It runs as
part of `npm run build` in that package.

**It fails loudly rather than defaulting**, and that is deliberate: a colour
that silently falls back is exactly the drift the script exists to prevent. Two
traps it already hit, both now guarded:

- `Surface.swift`'s header comment contains a `cornerRadius: 8` example of what
  NOT to do, and a `recessed` surface further down uses 12. A whole-file search
  took the first and shipped a card of the wrong shape. The extractor now scopes
  to `KhaytCard`'s own body and strips comment lines first.
- The card's `padding` DEFAULT is on the `card(...)` signature in the
  `extension View` ABOVE `KhaytCard`, so it is outside that scoped body. A bare
  `padding: CGFloat =` search found a different view's 10 instead of the card's
  12. It now matches the `func card(rail:` signature by name.

After any change to those four Swift files, re-run the package build and check
the generated CSS before trusting a sync.

## Build and sync

```sh
cd design-system && npm i && npm run build      # tokens → css → d.ts → bundle
cd .. && node .ds-sync/resync.mjs --config .design-sync/config.json \
  --node-modules design-system/node_modules --entry design-system/dist/index.js \
  --out ./ds-bundle --remote .design-sync/.cache/remote-sync.json
```

- `--entry` is required: the package is not installed into `node_modules`.
- `--node-modules design-system/node_modules` is where its React resolves.

## Things that cost time here

- **`cssEntry` must be self-contained.** The source is deliberately two files
  (generated tokens + authored styles), but a rendered design receives only the
  `@import` closure of the stylesheet it is handed, and `tokens/khayt.css` was
  not in it — every component rendered unstyled with `[CSS_IMPORT_MISSING]`.
  `design-system/build-css.mjs` flattens them into `dist/khayt.css`, which is
  what `cssEntry` points at. Keep it that way.
- **`cfg.tokensGlob` does nothing without `cfg.tokensPkg`.** `copyTokens`
  returns immediately when `tokensPkg` is unset, and it resolves inside
  `node_modules`. Khayt's tokens are in the DS package itself, so that route
  does not apply — hence the flattening above.
- **Fonts: ship the brand family only.** Pointing `extraFonts` at
  `renderer/fonts/fonts.css` pulled in 49 faces across 13 families (920K) — the
  whole Electron theme library. `TypeScale.brandFamily` is "Space Grotesk" and
  nothing else, so `design-system/src/fonts.css` carries just those four faces
  and references the repo's existing woff2 files rather than copying them. 68K.
- **Eight components need `cardMode: "column"`.** Their stories are wider than
  a grid cell and the product card crops them. Already in `cfg.overrides`.

## Motion is extracted too, as of 2026-09-21

`Motion.swift` is now the **fourth** Swift file the extractor reads, and it is
the one that makes the design tool useful for anything interactive. Before
this, the mirror shipped eleven static components and zero motion — so a
design agent asked for something "livelier" invented its own timings, which
is precisely what `Motion.swift` argues against.

What is read: the four `static let` durations on `Motion` (`figure`, `gauge`,
`progress`, `hover`) with their curves, plus the two named behaviours —
`Alive`'s breath duration and dim, and `Lift`'s percentage. They become
`--khayt-motion-*`, `--khayt-ease-*`, `--khayt-alive-dim` and `--khayt-lift`.

**Reduce Motion goes to ZERO, not slower**, and the breath stops rather than
resting dimmed. That is `Motion.swift`'s own position — a workshop app, a dot
somebody looks at all day — and the tokens carry it so no component has to
remember.

Two components gained a prop, both opt-in and both deliberately narrow:

* `Card pressable` — the lift. A card that opens nothing must not have it.
* `JobCard live` — the breathing amber dot. **The only self-starting motion in
  the system.** There is no general-purpose pulse, and there should not be.

## Known render warns

* **Hover and press states cannot be captured.** `Card`'s `Pressable` cell
  shows two cards side by side — one that opens something, one that does not
  — because the lift only exists under a pointer. The cell is graded on the
  API and the rule it demonstrates, not on visible movement. Same for the
  focus ring.
* `JobCard`'s `Live` cell catches the breath at one frame of its cycle, so the
  dot's opacity in the still is arbitrary. The dot being PRESENT on the
  running job and ABSENT on the other is what that cell proves.

## Re-sync risks

- **The extractor is the single point of drift.** It matches Swift by regex. A
  rename (`Khayt.surface`, `KhaytCard`, `TypeScale.display`) or a reshaped
  signature stops the build with a named error — good — but a colour ADDED to
  `Palette.swift` is silently absent, because `NEEDED` is a hand-written list.
  Check that list when the palette grows.
- **The mirror can fall behind the Mac app.** Components here were written from
  `Surface.swift`, `TypeScale.swift` and the board/sidebar views as they stood
  on 2026-09-17. Nothing detects a change to the Mac's own layout; only the
  token values are checked mechanically. If the Mac's card, board card or
  sidebar row changes shape, this package has to be updated by hand.
- **`design-system/` has its own lockfile-less `npm i`.** React resolves to
  whatever is current (19.x at the time of writing); the converter bundles it
  via esbuild because 19 ships no UMD. A major React change could move this.
- **The previews are authored, not generated.** They live in
  `.design-sync/previews/` and are committed. The converter never touches them.
  They reference sample shop data (Falcon hood, Acme Robotics) that is
  illustrative, not from the real book.
- **The project this syncs to was adopted, not created.** It held a
  componentless shell from an earlier failed run, which this run overwrote.
  `projectId` is pinned in `config.json`.
- **Motion.swift is now a fourth point of drift, with the same hand-written
  list problem as the palette.** `MOTION_NEEDED` names four durations; a
  duration ADDED to `Motion.swift` is silently absent from the tokens. Check
  that list when the motion vocabulary grows.
- **`Alive` and `Lift` are matched against implementation detail, not a
  signature.** The dim comes from the literal
  `.opacity(active && breathed && !reduced ? 0.45 : 1)` and the lift from
  `by amount: CGFloat = 1`. Both stop the build with a named error if they
  move — which is the intent — but they are tighter patterns than the
  duration regex and will need re-pointing if those modifiers are refactored.
- **The CSS curves are approximations.** SwiftUI's `.easeOut`/`.easeInOut` are
  mapped to CSS `ease-out`/`ease-in-out`. Close, not identical; if a motion
  ever has to match the Mac frame-for-frame, measure rather than assume.
