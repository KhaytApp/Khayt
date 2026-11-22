# Bed Ready screenshot library

12 screenshots, PNG, light theme.
Captured at 1480×940; dialog shots are cropped to the dialog, so
they are smaller. Set `BEDREADY_THEME=dark` to recapture in dark.
Demo data — no real customer content.

## Contents

- `01-dashboard.png` — Dashboard / home
- `02-print-files.png` — Print-file library
- `03-converter-landing.png` — Converter (landing)
- `04-colour-studio.png` — Colour studio
- `05-cost-calculator.png` — Print-cost calculator
- `06-filament-inventory.png` — Filament inventory
- `07-print-queue.png` — Print queue
- `08-waste-log.png` — Waste / failure log
- `09-settings-slicers.png` — Settings · slicer integration
- `10-converter-3d-preview.png` — Converter · 3D preview + target picker
- `11-full-spectrum.png` — Full Spectrum · mix plan (Snapmaker U1)
- `12-help-faq.png` — Help & FAQ

## Regenerate

```
npm run capture:bedready
```

The converter shots (10, 11) need local multicolour `.3mf` samples; override with
`BEDREADY_HERO_3MF` (single model for the 3D hero) and `BEDREADY_SAMPLE_3MF`
(>4 colours for Full Spectrum). Without them the other 10 shots still capture.
