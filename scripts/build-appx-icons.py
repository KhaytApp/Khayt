#!/usr/bin/env python3
"""Regenerate Microsoft Store (appx) PNGs from assets/icon_preview.png."""

from __future__ import annotations

import os
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
ICON = ROOT / "assets" / "icon_preview.png"
APPX = ROOT / "assets" / "appx"

# filename -> (width, height) — height None means square
TARGETS: dict[str, tuple[int, int | None]] = {
    "BadgeLogo.png": (24, 24),
    "StoreLogo.png": (50, 50),
    "Square44x44Logo.png": (44, 44),
    "Square44x44Logo.scale-100.png": (44, 44),
    "Square44x44Logo.scale-125.png": (55, 55),
    "Square44x44Logo.scale-150.png": (66, 66),
    "Square44x44Logo.scale-200.png": (88, 88),
    "Square44x44Logo.scale-400.png": (176, 176),
    "Square150x150Logo.png": (150, 150),
    "Square150x150Logo.scale-100.png": (150, 150),
    "Square150x150Logo.scale-125.png": (188, 188),
    "Square150x150Logo.scale-150.png": (225, 225),
    "Square150x150Logo.scale-200.png": (300, 300),
    "Square150x150Logo.scale-400.png": (600, 600),
    "SmallTile.png": (71, 71),
    "LargeTile.png": (310, 310),
    "Wide310x150Logo.png": (310, 150),
    "SplashScreen.png": (620, 300),
}


def fit_icon(src: Image.Image, w: int, h: int) -> Image.Image:
    """Letterbox icon on dark background matching Studio shell."""
    bg = Image.new("RGBA", (w, h), (11, 13, 18, 255))
    side = min(w, h)
    pad = int(side * 0.08)
    icon_max = side - pad * 2
    icon = src.resize((icon_max, icon_max), Image.LANCZOS)
    x = (w - icon_max) // 2
    y = (h - icon_max) // 2
    bg.paste(icon, (x, y), icon if icon.mode == "RGBA" else None)
    return bg.convert("RGBA")


def main() -> None:
    if not ICON.is_file():
        raise SystemExit(f"Missing {ICON} — run python3 make_icon.py first")
    src = Image.open(ICON).convert("RGBA")
    APPX.mkdir(parents=True, exist_ok=True)
    for name, (w, h) in TARGETS.items():
        h = h if h is not None else w
        out = fit_icon(src, w, h)
        out.save(APPX / name, optimize=True)
        print(f"  appx/{name}  {w}×{h}")
    print("Done.")


if __name__ == "__main__":
    main()
