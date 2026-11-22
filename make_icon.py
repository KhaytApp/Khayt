#!/usr/bin/env python3
"""
Khayt brand asset generator — hotend extruding layered Kha (خ).

Outputs:
  assets/khayt.iconset/*.png
  assets/icon_preview.png
  assets/icon-source.png          (master 1024, square)
  assets/icon.icns                (pure-Python builder; iconutil on macOS optional)
  assets/logo/mark-*.png          (transparent sidebar / invoice marks)

Run: python3 make_icon.py
"""

from __future__ import annotations

import io
import math
import os
import struct
import subprocess
import sys

from PIL import Image, ImageDraw, ImageFilter

# ── Studio palette (renderer/studio/ds.css) ───────────────────────────────────
BG       = (11, 13, 18)
BG_EDGE  = (20, 24, 31)
CYAN     = (43, 205, 228)
CYAN_HI  = (158, 242, 255)
CYAN_GLO = (43, 205, 228)
ORANGE   = (245, 166, 35)
ORANGE_HI = (255, 196, 80)
SILVER   = (188, 198, 210)
SILVER_D = (110, 118, 132)
SILVER_DK = (72, 78, 90)

# Kha (خ) centerline as cubic-bezier chains in 0..1 space (y down)
KHA_SEGMENTS = (
    ((0.60, 0.46), (0.54, 0.34), (0.42, 0.34), (0.38, 0.44)),
    ((0.38, 0.44), (0.30, 0.52), (0.28, 0.66), (0.40, 0.80)),
    ((0.40, 0.80), (0.52, 0.88), (0.68, 0.84), (0.64, 0.68)),
)
NUQTA = (0.48, 0.26)  # diamond center


def lerp(a, b, t):
    t = max(0.0, min(1.0, t))
    if isinstance(a, tuple):
        return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(len(a)))
    return a + (b - a) * t


def bezier(p0, p1, p2, p3, t):
    u = 1 - t
    return (
        u**3 * p0[0] + 3 * u**2 * t * p1[0] + 3 * u * t**2 * p2[0] + t**3 * p3[0],
        u**3 * p0[1] + 3 * u**2 * t * p1[1] + 3 * u * t**2 * p2[1] + t**3 * p3[1],
    )


def sample_kha(n_per_seg: int = 48) -> list[tuple[float, float]]:
    pts: list[tuple[float, float]] = []
    for seg in KHA_SEGMENTS:
        for i in range(n_per_seg):
            pts.append(bezier(*seg, i / n_per_seg))
    pts.append(KHA_SEGMENTS[-1][3])
    return pts


def offset_polyline(pts: list[tuple[float, float]], offset: float) -> list[tuple[float, float]]:
    out: list[tuple[float, float]] = []
    n = len(pts)
    for i, (x, y) in enumerate(pts):
        i0 = max(0, i - 1)
        i1 = min(n - 1, i + 1)
        tx = pts[i1][0] - pts[i0][0]
        ty = pts[i1][1] - pts[i0][1]
        length = math.hypot(tx, ty) or 1.0
        nx, ny = -ty / length, tx / length
        out.append((x + nx * offset, y + ny * offset))
    return out


def to_px(pts, ox, oy, scale):
    return [(ox + x * scale, oy + y * scale) for x, y in pts]


def rounded_rect_mask(size: int, radius: int) -> Image.Image:
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, size - 1, size - 1], radius=radius, fill=255)
    return mask


def draw_glow_stroke(
    draw: ImageDraw.ImageDraw,
    pts: list[tuple[float, float]],
    width: float,
    color: tuple[int, int, int],
    glow_alpha: int = 70,
):
    if len(pts) < 2:
        return
    glow = color + (glow_alpha,)
    core = color + (255,)
    draw.line(pts, fill=glow, width=int(width * 2.8), joint="curve")
    draw.line(pts, fill=core, width=max(1, int(width)), joint="curve")


def draw_kha_mark(
    draw: ImageDraw.ImageDraw,
    ox: float,
    oy: float,
    scale: float,
    layers: int = 3,
    stroke: float | None = None,
    glow: bool = True,
):
    center = sample_kha()
    spacing = 0.022 * (scale / 400)
    layer_offsets = [(i - (layers - 1) / 2) * spacing for i in range(layers)]
    sw = stroke if stroke is not None else max(2, scale * 0.014)

    for off in layer_offsets:
        pts = to_px(offset_polyline(center, off), ox, oy, scale)
        if glow:
            draw_glow_stroke(draw, pts, sw, CYAN)
        else:
            draw.line(pts, fill=CYAN + (255,), width=max(1, int(sw)), joint="curve")

    # Nuqta — diamond
    nx, ny = NUQTA
    r = scale * 0.028
    cx, cy = ox + nx * scale, oy + ny * scale
    diamond = [(cx, cy - r), (cx + r * 0.85, cy), (cx, cy + r), (cx - r * 0.85, cy)]
    if glow:
        draw.polygon(diamond, fill=CYAN + (90,))
    draw.polygon(diamond, fill=CYAN_HI + (255,))


def draw_hotend(draw: ImageDraw.ImageDraw, cx: float, cy: float, scale: float):
    """Simplified hotend — readable at 64px."""
    w = scale * 0.20
    h = scale * 0.09
    nx = scale * 0.045
    ny = scale * 0.055

    left = cx - w / 2
    top = cy - h / 2

    # Heat sink block
    for i in range(int(h)):
        t = i / max(h - 1, 1)
        c = lerp(SILVER, SILVER_D, t * 0.5)
        draw.rectangle([left, top + i, left + w, top + i + 1], fill=c + (255,))

    # Fins (3 vertical grooves)
    fin_w = max(1, int(w * 0.06))
    for fx in (0.25, 0.5, 0.75):
        fx_px = left + w * fx
        draw.rectangle([fx_px, top, fx_px + fin_w, top + h * 0.85], fill=SILVER_DK + (180,))

    # Nozzle body
    nb_w = w * 0.35
    nb_h = ny
    nb_left = cx - nb_w / 2
    nb_top = top + h
    draw.rounded_rectangle(
        [nb_left, nb_top, nb_left + nb_w, nb_top + nb_h * 0.75],
        radius=max(1, int(nb_w * 0.15)),
        fill=SILVER_D + (255,),
    )

    # Molten tip
    tip_r = max(2, int(scale * 0.018))
    tip_y = nb_top + nb_h * 0.85
    draw.ellipse([cx - tip_r * 1.4, tip_y - tip_r, cx + tip_r * 1.4, tip_y + tip_r * 2.2], fill=ORANGE + (120,))
    draw.ellipse([cx - tip_r, tip_y, cx + tip_r, tip_y + tip_r * 2], fill=ORANGE_HI + (255,))

    # Filament strand from tip to mark
    strand_top = tip_y + tip_r * 2
    strand_bot = cy + scale * 0.08
    draw.line([(cx, strand_top), (cx, strand_bot)], fill=CYAN + (200,), width=max(1, int(scale * 0.006)))


def render_background(size: int) -> Image.Image:
    img = Image.new("RGBA", (size, size), BG + (255,))
    draw = ImageDraw.Draw(img, "RGBA")
    for y in range(size):
        t = y / size
        c = lerp(BG, BG_EDGE, t * 0.6)
        draw.line([(0, y), (size - 1, y)], fill=c + (255,))

    # Subtle inner vignette
    glow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    gd = ImageDraw.Draw(glow, "RGBA")
    cx = cy = size / 2
    for r in range(int(size * 0.55), 0, -6):
        alpha = int(18 * (1 - r / (size * 0.55)))
        gd.ellipse([cx - r, cy - r, cx + r, cy + r], fill=CYAN_GLO + (alpha,))
    img.alpha_composite(glow)
    return img


def render_mark_transparent(size: int) -> Image.Image:
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img, "RGBA")
    margin = size * 0.12
    scale = size - margin * 2
    draw_kha_mark(draw, margin, margin, scale, stroke=max(2, size * 0.045))
    return img


def render_icon(final_size: int) -> Image.Image:
    s = final_size * 2  # 2× supersample
    img = render_background(s)
    draw = ImageDraw.Draw(img, "RGBA")

    cx = s * 0.5
    hotend_cy = s * 0.17
    mark_ox = s * 0.14
    mark_oy = s * 0.30
    mark_scale = s * 0.72

    draw_hotend(draw, cx, hotend_cy, s)
    draw_kha_mark(draw, mark_ox, mark_oy, mark_scale)

    # Extrusion shelf under mark
    shelf_y = mark_oy + mark_scale * 0.86
    shelf_l = mark_ox + mark_scale * 0.22
    shelf_r = mark_ox + mark_scale * 0.74
    draw.rounded_rectangle(
        [shelf_l, shelf_y, shelf_r, shelf_y + s * 0.012],
        radius=2,
        fill=CYAN + (140,),
    )

    radius = int(s * 0.224)
    mask = rounded_rect_mask(s, radius)
    img.putalpha(mask)
    return img.resize((final_size, final_size), Image.LANCZOS)


def png_bytes(img: Image.Image) -> bytes:
    buf = io.BytesIO()
    img.save(buf, format="PNG", optimize=True)
    return buf.getvalue()


def write_icns(out_path: str, master: Image.Image) -> None:
    type_sizes = {
        "icp4": 16,
        "icp5": 32,
        "ic07": 128,
        "ic08": 256,
        "ic09": 512,
        "ic10": 1024,
        "ic11": 32,
        "ic12": 64,
        "ic13": 256,
        "ic14": 512,
    }
    chunks = []
    for code, dim in type_sizes.items():
        resized = master.resize((dim, dim), Image.LANCZOS) if dim != master.width else master
        data = png_bytes(resized)
        chunk_len = 8 + len(data)
        chunks.append(code.encode("ascii") + struct.pack(">I", chunk_len) + data)
    body = b"".join(chunks)
    total = 8 + len(body)
    with open(out_path, "wb") as f:
        f.write(b"icns" + struct.pack(">I", total) + body)


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


def main() -> int:
    base = os.path.dirname(os.path.abspath(__file__))
    assets = os.path.join(base, "assets")
    iconset_dir = os.path.join(assets, "khayt.iconset")
    logo_dir = os.path.join(assets, "logo")
    os.makedirs(iconset_dir, exist_ok=True)
    os.makedirs(logo_dir, exist_ok=True)

    print("Rendering Khayt icon (1024×1024, 2× internal)…")
    master = render_icon(1024)
    master.save(os.path.join(assets, "icon_preview.png"), optimize=True)
    master.save(os.path.join(assets, "icon-source.png"), optimize=True)
    print("  icon_preview.png, icon-source.png")

    for fname, sz in ICONSET_SIZES.items():
        out = master.resize((sz, sz), Image.LANCZOS)
        out.save(os.path.join(iconset_dir, fname), optimize=True)
        print(f"  khayt.iconset/{fname} ({sz}px)")

    print("Rendering transparent marks…")
    mark_master = render_mark_transparent(512)
    for sz in MARK_SIZES:
        out = mark_master.resize((sz, sz), Image.LANCZOS) if sz != 512 else mark_master
        out.save(os.path.join(logo_dir, f"mark-{sz}.png"), optimize=True)
        print(f"  logo/mark-{sz}.png")

    icns_path = os.path.join(assets, "icon.icns")
    write_icns(icns_path, master)
    print(f"  icon.icns ({os.path.getsize(icns_path):,} bytes, pure-Python)")

    if sys.platform == "darwin":
        ret = subprocess.call(["iconutil", "-c", "icns", iconset_dir, "-o", icns_path])
        print("  iconutil refreshed icon.icns" if ret == 0 else "  iconutil skipped")

    print("Done. Run: python3 scripts/build-appx-icons.py")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
