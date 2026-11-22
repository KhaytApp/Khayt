#!/usr/bin/env python3
"""
Wire Claude / manual logo exports into Khayt assets.

Drop PNGs into one of:
  export/
  assets/logo-exports/
  Khayt/export/   (if present at repo root)

Naming (any match works):
  App icon:  icon*.png, app-icon*.png, *1024*.png, largest square PNG
  Mark:      mark*.png, logo*.png, sidebar*.png, smallest transparent PNG

Preferred: cyan/blue variant over orange if both exist (filename contains blue/cyan).

Then run:
  python3 scripts/wire-logo-exports.py
  # or: npm run wire:logo
"""

from __future__ import annotations

import io
import os
import re
import struct
import subprocess
import sys
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parents[1]

SEARCH_DIRS = (
    ROOT / "export",
    ROOT / "assets" / "logo-exports",
    ROOT / "Khayt" / "export",
    ROOT / "khayt" / "export",
)

ICON_OUT = ROOT / "assets" / "icon_preview.png"
ICON_SOURCE = ROOT / "assets" / "icon-source.png"
ICONSET = ROOT / "assets" / "khayt.iconset"
ICNS = ROOT / "assets" / "icon.icns"
LOGO_DIR = ROOT / "assets" / "logo"
RENDERER_MARK = ROOT / "renderer" / "logo" / "khayt-mark.png"

ICONSET_SIZES = {
    "icon_16x16.png": 16,
    "icon_16x16@2x.png": 32,
    "icon_32x32.png": 32,
    "icon_32x32@2x.png": 64,
    "icon_128x128.png": 128,
    "icon_128x128@2x.png": 256,
    "icon_256x256.png": 256,
    "icon_256x256@2x.png": 512,
    "icon_512x512.png": 512,
    "icon_512x512@2x.png": 1024,
    "icon_1024x1024.png": 1024,
}

MARK_SIZES = (32, 64, 128, 256, 512)
LOCKUP_OUT = ROOT / "assets" / "logo" / "khayt-lockup.png"
FAVICON_OUT = ROOT / "assets" / "logo" / "favicon.ico"

# Claude export layout (export/icon-a/, export/mark-cyan/, …)
EXPLICIT_ICON = (
    ROOT / "export" / "icon-a" / "khayt-icon-1024.png",
    ROOT / "export" / "icon-b" / "khayt-iconB-512.png",
)
EXPLICIT_MARK = (
    ROOT / "export" / "mark-cyan" / "khayt-mark-512.png",
    ROOT / "export" / "mark-cyan" / "khayt-mark-1024.png",
    ROOT / "export" / "mark-teal" / "khayt-mark-teal-512.png",
)
EXPLICIT_LOCKUP = ROOT / "export" / "lockup" / "khayt-lockup-1200x400.png"
EXPLICIT_FAVICON = ROOT / "export" / "khayt-favicon.ico"


def png_bytes(img: Image.Image) -> bytes:
    buf = io.BytesIO()
    img.save(buf, format="PNG", optimize=True)
    return buf.getvalue()


def write_icns(out_path: Path, master: Image.Image) -> None:
    type_sizes = {
        "icp4": 16, "icp5": 32, "ic07": 128, "ic08": 256, "ic09": 512,
        "ic10": 1024, "ic11": 32, "ic12": 64, "ic13": 256, "ic14": 512,
    }
    chunks = []
    for code, dim in type_sizes.items():
        resized = master.resize((dim, dim), Image.LANCZOS) if dim != master.width else master
        data = png_bytes(resized)
        chunk_len = 8 + len(data)
        chunks.append(code.encode("ascii") + struct.pack(">I", chunk_len) + data)
    body = b"".join(chunks)
    out_path.write_bytes(b"icns" + struct.pack(">I", 8 + len(body)) + body)


def has_transparency(img: Image.Image) -> bool:
    if img.mode != "RGBA":
        return False
    alpha = img.getchannel("A")
    return alpha.getextrema()[0] < 255


def score_icon_candidate(path: Path, w: int, h: int) -> float:
    name = path.stem.lower()
    score = 0.0
    if w == h:
        score += w
    if re.search(r"icon|app", name):
        score += 5000
    if "1024" in name or "512" in name:
        score += 2000
    if re.search(r"blue|cyan|glow", name):
        score += 1500
    if re.search(r"orange|molten", name):
        score += 500
    if re.search(r"mark|sidebar|glyph|favicon", name):
        score -= 3000
    if has_transparency(Image.open(path).convert("RGBA")):
        score -= 800
    return score


def score_mark_candidate(path: Path, w: int, h: int, img: Image.Image) -> float:
    name = path.stem.lower()
    score = 0.0
    if re.search(r"mark|sidebar|glyph|favicon|logo", name) and not re.search(r"app.?icon", name):
        score += 4000
    if has_transparency(img):
        score += 2000
    if w == h and w <= 512:
        score += w
    if re.search(r"blue|cyan|glow", name):
        score += 800
    if re.search(r"icon|1024|app", name):
        score -= 2000
    return score


def find_exports() -> list[Path]:
    files: list[Path] = []
    for d in SEARCH_DIRS:
        if not d.is_dir():
            continue
        for p in sorted(d.rglob("*")):
            if p.suffix.lower() in (".png", ".webp", ".jpg", ".jpeg"):
                files.append(p)
    return files


def first_existing(paths: tuple[Path, ...]) -> Path | None:
    for p in paths:
        if p.is_file():
            return p
    return None


def pick_assets(files: list[Path]) -> tuple[Path, Path | None]:
    icon_explicit = first_existing(EXPLICIT_ICON)
    mark_explicit = first_existing(EXPLICIT_MARK)
    if icon_explicit:
        return icon_explicit, mark_explicit

    if not files:
        raise SystemExit(
            "No logo PNGs found. Expected Claude exports under export/, e.g.:\n"
            "  export/icon-a/khayt-icon-1024.png\n"
            "  export/mark-cyan/khayt-mark-512.png\n"
            "Then run: npm run wire:logo"
        )

    icon_best: tuple[float, Path] | None = None
    mark_best: tuple[float, Path] | None = None

    for path in files:
        img = Image.open(path)
        w, h = img.size
        img_rgba = img.convert("RGBA")

        is_score = score_icon_candidate(path, w, h)
        if icon_best is None or is_score > icon_best[0]:
            icon_best = (is_score, path)

        ms = score_mark_candidate(path, w, h, img_rgba)
        if mark_best is None or ms > mark_best[0]:
            mark_best = (ms, path)

    assert icon_best is not None
    icon_path = icon_best[1]
    mark_path = mark_best[1] if mark_best and mark_best[1] != icon_path else None
    return icon_path, mark_path


def ensure_square_icon(img: Image.Image, size: int = 1024) -> Image.Image:
    img = img.convert("RGBA")
    w, h = img.size
    if w != h:
        side = max(w, h)
        sq = Image.new("RGBA", (side, side), (11, 13, 18, 255))
        sq.paste(img, ((side - w) // 2, (side - h) // 2), img)
        img = sq
    if img.size[0] != size:
        img = img.resize((size, size), Image.LANCZOS)
    return img


def write_iconset(master: Image.Image) -> None:
    ICONSET.mkdir(parents=True, exist_ok=True)
    for fname, sz in ICONSET_SIZES.items():
        out = master.resize((sz, sz), Image.LANCZOS)
        out.save(ICONSET / fname, optimize=True)
        print(f"  khayt.iconset/{fname}")


def write_marks(mark_src: Image.Image) -> None:
    LOGO_DIR.mkdir(parents=True, exist_ok=True)
    RENDERER_MARK.parent.mkdir(parents=True, exist_ok=True)
    mark = mark_src.convert("RGBA")
    side = max(mark.size)
    if mark.size[0] != mark.size[1]:
        sq = Image.new("RGBA", (side, side), (0, 0, 0, 0))
        sq.paste(mark, ((side - mark.width) // 2, (side - mark.height) // 2), mark)
        mark = sq
    base = mark.resize((512, 512), Image.LANCZOS) if side != 512 else mark
    for sz in MARK_SIZES:
        out = base.resize((sz, sz), Image.LANCZOS) if sz != 512 else base
        out.save(LOGO_DIR / f"mark-{sz}.png", optimize=True)
    base.resize((64, 64), Image.LANCZOS).save(RENDERER_MARK, optimize=True)
    print(f"  renderer/logo/khayt-mark.png")
    print(f"  assets/logo/mark-*.png")


def main() -> int:
    files = find_exports()
    print(f"Found {len(files)} image(s) in export folders")
    for f in files:
        im = Image.open(f)
        print(f"  {f.relative_to(ROOT)}  {im.size[0]}×{im.size[1]}")

    icon_path, mark_path = pick_assets(files)
    print(f"\nApp icon source: {icon_path.relative_to(ROOT)}")
    if mark_path:
        print(f"Sidebar mark source: {mark_path.relative_to(ROOT)}")
    else:
        print("Sidebar mark: derived from app icon (center crop)")

    master = ensure_square_icon(Image.open(icon_path))
    master.save(ICON_OUT, optimize=True)
    master.save(ICON_SOURCE, optimize=True)
    print(f"\nWrote {ICON_OUT.relative_to(ROOT)}")

    write_iconset(master)
    write_icns(ICNS, master)
    print(f"  {ICNS.relative_to(ROOT)}")

    if mark_path:
        write_marks(Image.open(mark_path))
    else:
        # Crop center ~55% as mark fallback
        w = master.width
        crop = int(w * 0.225)
        cropped = master.crop((crop, crop, w - crop, w - crop))
        write_marks(cropped)

    appx = ROOT / "scripts" / "build-appx-icons.py"
    print("\nMicrosoft Store tiles…")
    subprocess.check_call([sys.executable, str(appx)])

    if EXPLICIT_LOCKUP.is_file():
        LOCKUP_OUT.parent.mkdir(parents=True, exist_ok=True)
        Image.open(EXPLICIT_LOCKUP).convert("RGBA").save(LOCKUP_OUT, optimize=True)
        print(f"  {LOCKUP_OUT.relative_to(ROOT)}")

    if EXPLICIT_FAVICON.is_file():
        import shutil
        FAVICON_OUT.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(EXPLICIT_FAVICON, FAVICON_OUT)
        print(f"  {FAVICON_OUT.relative_to(ROOT)}")

    print("\nDone. Run npm start to see sidebar mark; icon updates after rebuild/reinstall.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
