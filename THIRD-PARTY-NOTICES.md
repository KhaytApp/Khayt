# Third-party notices

Khayt bundles or redistributes the third-party components below. Each is the
property of its respective authors and is used under its own license. This file
is provided for attribution; the full license texts ship with each package under
`node_modules/<name>/LICENSE`.

## Runtime libraries (MIT License)

| Component | License |
|-----------|---------|
| Electron (and its bundled Chromium / Node.js runtimes) | MIT (Chromium: BSD-3-Clause; Node: MIT) |
| electron-updater | MIT |
| localtunnel | MIT |
| qrcode | MIT |

The MIT License permits use, copying, modification, and redistribution provided
the copyright notice and permission notice are preserved.

## Fonts (SIL Open Font License 1.1)

The following typefaces are bundled via `@fontsource/*` and are licensed under the
**SIL Open Font License, Version 1.1** (OFL-1.1):

Albert Sans · Archivo · Bricolage Grotesque · Hanken Grotesk · IBM Plex Mono ·
IBM Plex Sans · IBM Plex Sans Arabic · JetBrains Mono · Newsreader · Outfit ·
Plus Jakarta Sans · Space Grotesk · Spline Sans Mono

Under OFL-1.1 these fonts may be bundled and redistributed with the software
(including commercially) provided they are not sold on their own and the OFL
license accompanies them. Reserved Font Names belong to their respective authors;
see each font's `OFL.txt` / `LICENSE` under `node_modules/@fontsource/<name>`.

---

## Data: the filament catalogue

`assets/filament-catalog.json` (and its copy in the Mac app,
`mac/KhaytCore/Sources/KhaytApp/Resources/filament-catalog.json`) is a trimmed,
merged snapshot built by `scripts/fetch-filament-catalog.py` from the sources
below. Every row names the sources it came from (`s`), the file lists them with
their licences (`sources`), and it carries the MIT permission notice itself
(`mitNotice`), because the app bundles that ship it carry no NOTICES file.

| Letter | Source | Licence | Used for |
|---|---|---|---|
| `o` | [Open Filament Database](https://github.com/OpenFilamentCollective/open-filament-database) — Copyright (c) 2025 OpenFilamentCollective, facilitated by SimplyPrint | **MIT** | the base list: products, colours, hexes, spool and empty-reel weights, diameters, densities, print and bed temperatures |
| `s` | [SpoolmanDB](https://github.com/Donkie/SpoolmanDB) — Copyright (c) 2024 Donkie | **MIT** | brands, lines and colours the OFD lacks; fills missing weights, temperatures and densities. Never overrides the OFD |
| `b` | [Bambu Lab's colour list](https://github.com/bambulab/BambuStudio/blob/master/resources/profiles/BBL/filament/filaments_color_codes.json) in Bambu Studio | **facts only** — see below | Bambu Lab product lines, English colour names and hexes |
| `k` | [`scripts/filament-catalog-overrides.json`](https://github.com/KhaytApp/Khayt/blob/main/scripts/filament-catalog-overrides.json) | Khayt's own | corrections checked against the manufacturer, applied last |

**About the Bambu Lab list.** The file sits in the Bambu Studio repository,
which is AGPL-3.0. Khayt does not ship that file, its structure, its internal
codes or its translations. The build reads three facts from each entry — which
product line a colour belongs to, its English name and its hex — which Bambu Lab
publishes on its own store for anyone selling or buying its filament. Facts are
not copyrightable, but if Bambu Lab objects, drop the source: remove `"b"` from
`build()` in the script and rebuild.

**Not used:** OrcaSlicer and Bambu Studio filament *profiles* (AGPL-3.0, and they
hold temperatures and flow, not colours) and retailer or manufacturer web pages
(no licence to copy them wholesale).

Khayt ships a snapshot rather than querying any of these: a shop with no signal
must still be able to add a spool, and asking a third party what a shop buys is
a thing to avoid rather than a feature. The file records the date it was
generated so the app can say how old it is. Discontinued products are dropped.

Only the fields a spool record needs are kept: brand, product, material,
density, print and bed temperatures, colour names and hexes, spool weights, spool
diameters and empty-spool weights.

The MIT licence, as it applies to both MIT sources:

> Permission is hereby granted, free of charge, to any person obtaining a copy
> of this software and associated documentation files (the "Software"), to deal
> in the Software without restriction, including without limitation the rights
> to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
> copies of the Software, and to permit persons to whom the Software is
> furnished to do so, subject to the following conditions:
>
> The above copyright notice and this permission notice shall be included in
> all copies or substantial portions of the Software.
>
> THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
> IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
> FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
> AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
> LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
> OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
> SOFTWARE.

---

*Build- and test-only dependencies (electron-builder, playwright-core, jsdom,
etc.) are not redistributed in the shipped application and are therefore not
listed here. Regenerate this list after dependency changes.*
