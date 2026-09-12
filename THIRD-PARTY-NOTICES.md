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

## Data: the Open Filament Database (MIT)

`assets/filament-catalog.json` is a trimmed snapshot of the
[Open Filament Database](https://github.com/OpenFilamentCollective/open-filament-database),
a community-maintained catalogue of filament products facilitated by
SimplyPrint, licensed **MIT**.

Khayt ships a snapshot rather than querying the service: a shop with no signal
must still be able to add a spool, and asking a third party what a shop buys is
a thing to avoid rather than a feature. `scripts/fetch-filament-catalog.py`
rebuilds it, and the file records the date it was generated so the app can say
how old it is.

Only the fields a spool record needs are kept — brand, product, material,
density, print temperatures, colour names and hexes, spool weights, spool
diameters and empty-spool weights. Discontinued products are dropped.

---

*Build- and test-only dependencies (electron-builder, playwright-core, jsdom,
etc.) are not redistributed in the shipped application and are therefore not
listed here. Regenerate this list after dependency changes.*
