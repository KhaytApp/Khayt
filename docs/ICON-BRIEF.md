# Khayt app icon — prompt for an image/logo AI

Paste the **Prompt** section. The sections after it are the brief the prompt is
compressed from — use them to judge what comes back, and to argue with it.

---

## Requirements

### What the app is

**Khayt** is desktop software that keeps a 3D printing shop's book — not a
printer monitor, and not a generic business tool. It holds the jobs a shop has
taken, what each one actually cost in filament and machine hours, what was
charged, what is on the shelf, what the printers are doing, and what any of it
earned. Quotes, invoices, VAT, inventory, customers, reports.

It is for small shops — one to twenty machines. It is free, works entirely
offline, and keeps everything in one file the shop owns. No account, no
subscription, nothing leaves the building unless the owner asks it to.

**The name.** *Khayt* (خيط) is Arabic for **thread**, and it earns the name
twice over: filament is thread, and the app is the thread that runs through a
job from the first message to the invoice. Continuity and keeping track are what
it is for.

**Who opens it.** A shop owner, most often in Saudi Arabia, every morning, to
find out where the money is. Arabic is a first-class language here — the whole
interface mirrors right to left, and nine languages ship. This is a tool
somebody works in all day, so it should read as steady, exact and calm rather
than loud or playful. It sits in a Dock next to Mail and Numbers, not next to a
game.

**What it is not.** Not a slicer. Not a printer dashboard. Not a toy for
hobbyists — it is the ledger of a business that happens to be made of plastic.

### Deliverable
- 1024 × 1024 px, square.
- Artwork bleeds to all four edges. No container drawn inside it.
- Supplied as two separate layers: one opaque full-bleed background, one
  foreground. Vector (SVG or PDF) preferred; PNG if raster.
- Any text converted to outlines.

### Must
- Read at 16 px. That is the size it is judged at, not 1024.
- Use a minimal number of shapes.
- Keep all strokes thick and all corners generous.
- Keep edges hard and clearly defined.
- Keep the primary content centred, away from the edges — the system crops
  foreground layers more than background layers.
- Keep the same core features when recoloured for dark and tinted appearances.
- Use Khayt's colours: filament orange **#DF6011** on navy **#0A2A50**, with a
  chrome nozzle in greys (#D0D0D0 lit to #808080 in shadow).

  > **This line said "the brand cyan: #2BCDE4 / #0A6E81" until 13 Sep 2026,
  > which was two brands out of date.** The icon became orange-on-navy in
  > `#1187`, and the app's UI accent moved to the icon's navy in `#1209`. A
  > brief is the one document that gets pasted into a generator verbatim, so a
  > stale colour here does not sit quietly — it comes back as artwork.

### Banned
- A rounded-rectangle container, border, bezel, frame or drop shadow. The system
  draws the corners, the shadow and the highlight.
- Black or near-black backgrounds.
- Glow, blur, soft edges, feathered edges, bokeh, gloss, 3D bevels,
  skeuomorphism, photorealism.
- Thin strokes, hairlines, fine detail, sharp or spiky corners.
- Concave shapes or anything meant to read as a hole in the background layer.
- Latin text, the app name, or any word.
- Replicating standard UI components, or screenshots of the app.
- A misformed, mirrored or approximate Arabic letter. Either correct, or absent.

### Banned because it is what everyone already draws
- Printers, nozzles, hotends, extruders, print beds, gantries.
- Filament spools, gears, cubes, benchies, layer or striation lines.

## The hard constraints, and where they come from

These are Apple's, quoted from the current Human Interface Guidelines
([App icons](https://developer.apple.com/design/human-interface-guidelines/app-icons)).
They are why the "do not" list is shaped as it is:

- **"Supply square, full-bleed layers so the system can apply rounded corners.
  Providing layers with pre-defined masking negatively impacts specular
  highlight effects and makes edges look jagged."** macOS 26 draws the corner
  radius, the shadow and the Liquid Glass highlight itself. A baked-in rounded
  rectangle is now a defect.
- **"Avoid using black for your icon's background. Lighten a black background so
  the icon doesn't blend into the display background."**
- **"Avoid soft and feathered edges on foreground layer shapes"**, so the
  system-drawn highlight has something clean to catch.
- **"Make sure to avoid extremely thin line weights and sharp corners, because
  they tend to lose detail and crispness in smaller icon sizes."**
- **"Find a concept or element that captures the essence of your app… and
  express it in a simple, unique way with a minimal number of shapes."**
- **"Displaying a mnemonic like the first letter of your app's name can help
  people recognize your app"** — which is what earns the خ its place.
- Deliverable is **1024×1024**, square, layered, and the system generates the
  dark / clear / tinted variants from it.

## What is wrong with the icon we have

Worth knowing so the new one is not a restyle of the same mistakes. The current
icon is a dark rounded square holding **four** separate objects — a detailed
hotend with cooling fins, a molten drop, a cyan diamond, and a خ built from
striped print layers, over a soft shadow ellipse.

- Four objects and high-frequency stripes become mud below about 64px.
- The background is near-black, against Apple's explicit guidance.
- It bakes in its own rounded rectangle and its own shadow.
- The glow and the shadow ellipse are the feathered edges the system cannot
  light properly.

The idea underneath it is good — a خ made of filament — and the existing
`assets/logo/khayt-mark.svg` already reaches for it with three parallel
filament strokes. Three strokes at that weight is the thin-line problem. **One
thread, thick, is the same idea that survives being small.**

## A warning about generated Arabic letterforms

Image models are unreliable with Arabic script. Expect the first attempts to
produce something that merely *resembles* خ, or a mirrored or malformed glyph —
the failure I hit drawing it by hand was a shape that read as a treble clef.

Two ways through:

1. Ask the model for the **container and style only** — background, colour,
   lighting, mood — and composite the letterform yourself. The correct
   outline is available from the system font: `/System/Library/Fonts/
   SFArabicRounded.ttf`, U+062E, whose rounded terminals already look like
   extruded filament.
2. Or judge every candidate against the real glyph side by side, and reject any
   that is close-but-wrong. A wrong خ is worse than no letter — it is the
   shop's own language, misspelled, on the app they open every day.

## How to judge what comes back

1. Render it at **16, 32, 64, 128, 256, 1024** and look at the small end first.
   If it fails at 32 it fails, however good 1024 looks.
2. Put it on a light desktop and a dark one. It must not merge into either.
3. Show the خ to somebody who reads Arabic, without telling them what it is.
4. Squint. Two shapes should remain two shapes.
