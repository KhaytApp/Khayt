# Credits & Third-Party Notices

Bed Ready (and the Khayt app it shares a core with) is source-available under **FSL-1.1-Apache-2.0**
(see `LICENSE`). This file credits the external work Bed Ready builds on. If you believe something is
missing or mis-attributed, please contact **support@khaytapp.com** — we want this to be complete and honest.

## Runtime / platform

- **Electron** — MIT License. https://github.com/electron/electron
- **Node.js** — MIT-style license. https://nodejs.org

## Colour science & filament mixing (the "Full Spectrum" feature)

- The pigment-mixing model in `lib/filament-mixer.js` is a degree-4 polynomial that **approximates the
  filament mixer used by Snapmaker Orca's "Full Spectrum" colour matching**
  (`src/libslic3r/filament_mixer_model.h`), which is distributed under the **MIT License,
  © 2026 Justin Hayes**. Bed Ready ports/regenerates this approximation from its own web app; the
  coefficient tables are generated, not hand-written.
- That model in turn **approximates [Mixbox](https://github.com/scrtwpns/mixbox)** (Secret Weapons /
  Šárka Sochorová & Ondřej Jamriška), a natural pigment-mixing model. Bed Ready uses a trained
  polynomial approximation, **not** Mixbox's code or data.
- **CIEDE2000 (ΔE00)** colour-difference — an open CIE technical standard; no license required.
- sRGB ⇄ CIELAB conversions — standard public formulas.

## Slicer profiles (read at runtime, not bundled)

- The converter **reads** printer, print, and filament profiles from the user's **own installed**
  **[OrcaSlicer](https://github.com/SoftFever/OrcaSlicer)** (AGPL-3.0) and **Snapmaker Orca**
  (an OrcaSlicer fork). These profiles are read from the installed application on the user's machine
  to build a compatible output file. **Bed Ready does not bundle, copy, or redistribute** these
  profiles; if the slicer is not installed, the feature simply falls back to generic defaults.
- The 3MF paint/segmentation codec and multi-plate handling were reverse-engineered for
  interoperability with Bambu Studio / OrcaSlicer / Snapmaker Orca project files.

## 3D preview

- The 3D viewer (`renderer/webgl-viewer.js`) is a **custom WebGL2 renderer written for Bed Ready** — it
  does **not** use three.js or any other third-party 3D engine.

## Ported from Bed Ready's web app

- The paint-colour decoder (`lib/mf-mesh.js`), the colour-mixing/planning logic (`lib/full-spectrum.js`),
  and the mesh preview approach are ported from **bedready.io**, the project owner's own web application.

## Trademarks

Snapmaker, Bambu Lab, Prusa Research, Creality, UltiMaker/Cura, Raise3D/ideaMaker, FlashForge, Elegoo,
Anycubic, QIDI, and all other product and company names are trademarks of their respective owners.
Bed Ready is an independent tool and is **not affiliated with, sponsored by, or endorsed by** any of
them. Names are used only to describe compatibility.

## Fonts

- UI fonts are bundled/self-hosted per their respective open-font licenses (see `renderer/fonts/`).

---

*This notice covers the primary third-party components. The full dependency tree and their licenses can
be enumerated from `package.json` / `package-lock.json`.*
