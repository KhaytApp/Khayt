#!/usr/bin/env python3
"""Turn four transparent master images into every icon asset Khayt ships.

Four pictures get generated. Everything else is arithmetic, and arithmetic is
mine — a generator asked for the same mark twenty times returns twenty subtly
different marks, and an icon set whose 32px and 512px disagree looks broken in a
way nobody can quite point at.

    masters/fg.png        2048x2048  transparent  the mark
    masters/fg-small.png  1024x1024  transparent  OPTIONAL: a simplified variant
                                                  used at 64px and under
    masters/lockup.png    3600x1200  transparent  horizontal, with KHAYT
    masters/mono.png      1024x1024  transparent  flat black silhouette

The navy ground is NOT generated. It is rebuilt here from the three colours
measured off candidate 45, which is what lets the same foreground serve both the
flat .icns and the macOS 26 layered icon — those need the layers kept apart, and
a foreground with its background baked in cannot be taken apart again.

    python3 derive.py stage
    rsync -av stage/ ~/Khayt/
"""
import os
import subprocess
import sys

import numpy as np
from PIL import Image

OUT = sys.argv[1] if len(sys.argv) > 1 else 'stage'
M = 'masters'

# Where the simplified master takes over, when one is supplied. Measured: the
# rejected detailed mark was 1.06px wide at 32px against 2.38px for one that
# survives, which is what the switch is guarding against.
SMALL_AT_OR_UNDER = 64

TOP = (0x0A, 0x2A, 0x51)   # navy at the top edge
BOT = (0x30, 0x34, 0x40)   # slate along the bottom
GLOW = (0x1F, 0x34, 0x53)  # the radial lift behind the mark


def load(name):
    return Image.open(os.path.join(M, name)).convert('RGBA')


def ground(px):
    """Candidate 45's background: a radial glow over a vertical navy fade."""
    y, x = np.mgrid[0:px, 0:px].astype(float) / max(px - 1, 1)
    base = (np.array(TOP, float)[None, None, :] * (1 - y[..., None])
            + np.array(BOT, float)[None, None, :] * y[..., None])
    r = np.sqrt((x - .5) ** 2 + (y - .42) ** 2) / .72
    k = np.clip(1 - r, 0, 1)[..., None] ** 1.6
    rgb = np.clip(base * (1 - k) + np.array(GLOW, float)[None, None, :] * k, 0, 255)
    return Image.fromarray(rgb.astype(np.uint8)).convert('RGBA')


def save(im, rel, size=None, opaque=False):
    p = os.path.join(OUT, rel)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    if size:
        im = im.resize((size, size), Image.LANCZOS)
    im.convert('RGB' if opaque else 'RGBA').save(p)
    return rel


def compose(px, fg, fg_small, inset=.80):
    """A finished square icon: the right foreground, centred on the ground."""
    art = fg_small if px <= SMALL_AT_OR_UNDER else fg
    out = ground(px)
    w = max(int(px * inset), 1)
    h = max(round(w * art.height / art.width), 1)
    out.alpha_composite(art.resize((w, h), Image.LANCZOS), ((px - w) // 2, (px - h) // 2))
    return out


def band(im, w, h, frac=.72, bg=True):
    """Centre a transparent image on a wide canvas (tiles, splash, og:image)."""
    out = Image.new('RGBA', (w, h), (*TOP, 255) if bg else (0, 0, 0, 0))
    tw = int(min(w, h * im.width / im.height) * frac)
    th = max(round(tw * im.height / im.width), 1)
    out.alpha_composite(im.resize((tw, th), Image.LANCZOS), ((w - tw) // 2, (h - th) // 2))
    return out


def silhouette(mono, px, colour=(0, 0, 0)):
    """Flat one-colour art: alpha from the master, colour imposed."""
    a = mono.resize((px, px), Image.LANCZOS).getchannel('A')
    out = Image.new('RGBA', (px, px), (*colour, 0))
    out.putalpha(a)
    return out


def main():
    fg = load('fg.png')
    # One mark at every size unless a simplified variant is supplied. The
    # switch exists because a detailed mark can stop being legible when small;
    # it is not needed when the mark was drawn simple to begin with.
    small = load('fg-small.png') if os.path.exists(os.path.join(M, 'fg-small.png')) else fg
    lockup, mono = load('lockup.png'), load('mono.png')
    made = []
    sq = lambda px: compose(px, fg, small)

    # ── macOS: the native app and Electron's mac build share this .icns ─────
    iconset = 'assets/khayt.iconset'
    for base in (16, 32, 64, 128, 256, 512):
        made += [save(sq(base), f'{iconset}/icon_{base}x{base}.png'),
                 save(sq(base * 2), f'{iconset}/icon_{base}x{base}@2x.png')]
    made.append(save(sq(1024), f'{iconset}/icon_1024x1024.png'))
    # iconutil rejects an iconset containing names it does not know (64 is one),
    # so the .icns is built from a copy holding only the canonical sizes.
    tmp = os.path.join(OUT, 'assets/_icns.iconset')
    os.makedirs(tmp, exist_ok=True)
    for base in (16, 32, 128, 256, 512):
        sq(base).save(f'{tmp}/icon_{base}x{base}.png')
        sq(base * 2).save(f'{tmp}/icon_{base}x{base}@2x.png')
    subprocess.run(['iconutil', '-c', 'icns', tmp,
                    '-o', os.path.join(OUT, 'assets/icon.icns')], check=True)
    subprocess.run(['rm', '-rf', tmp], check=True)
    made.append('assets/icon.icns')

    # ── macOS 26 layered icon ───────────────────────────────────────────────
    # Tahoe composites the layers itself and draws its own corner, shadow and
    # specular pass. It needs them apart, which is the whole reason the masters
    # are transparent. Open these two in Icon Composer and export Khayt.icon.
    made += [save(ground(1024), 'assets/icon-layers/background.png', opaque=True),
             save(band(fg, 1024, 1024, frac=.80, bg=False),
                  'assets/icon-layers/foreground.png')]

    # ── Electron: Windows, Linux, runtime Dock ──────────────────────────────
    p = os.path.join(OUT, 'assets/icon.ico')
    os.makedirs(os.path.dirname(p), exist_ok=True)
    sq(256).save(p, sizes=[(s, s) for s in (16, 24, 32, 48, 64, 128, 256)])
    made += ['assets/icon.ico',
             save(sq(1024), 'assets/icon_preview.png'),
             save(sq(1024), 'assets/icon-source.png')]

    # ── Windows Store tiles ─────────────────────────────────────────────────
    for name, px in (('Square44x44Logo', 44), ('Square150x150Logo', 150),
                     ('SmallTile', 71), ('LargeTile', 310), ('StoreLogo', 50)):
        made.append(save(sq(px), f'assets/appx/{name}.png'))
        for scale in (100, 125, 150, 200, 400):
            made.append(save(sq(max(round(px * scale / 100), 1)),
                             f'assets/appx/{name}.scale-{scale}.png'))
    # Microsoft's badge is a monochrome white-on-transparent glyph, never a
    # colour downscale — Windows tints it per theme, as macOS does a template.
    made.append(save(silhouette(mono, 24, (255, 255, 255)), 'assets/appx/BadgeLogo.png'))
    made += [save(band(lockup, 310, 150), 'assets/appx/Wide310x150Logo.png'),
             save(band(lockup, 620, 300), 'assets/appx/SplashScreen.png')]

    # ── iOS companion ───────────────────────────────────────────────────────
    # One 1024 and Xcode does the rest — but it MUST be opaque. App Store
    # Connect rejects an app icon carrying an alpha channel, and the one in the
    # repo today has one.
    made.append(save(sq(1024), 'ios/KhaytCompanion/Resources/Assets.xcassets/'
                               'AppIcon.appiconset/AppIcon.png', opaque=True))

    # ── assets/logo ─────────────────────────────────────────────────────────
    for px in (32, 64, 128, 256, 512):
        made.append(save(sq(px), f'assets/logo/mark-{px}.png'))
    p = os.path.join(OUT, 'assets/logo/favicon.ico')
    os.makedirs(os.path.dirname(p), exist_ok=True)
    sq(48).save(p, sizes=[(16, 16), (32, 32), (48, 48)])
    made += ['assets/logo/favicon.ico',
             save(band(lockup, 1200, 400, frac=.86), 'assets/logo/khayt-lockup.png'),
             save(band(lockup, 1200, 630), 'assets/logo/og-image.png'),
             save(sq(180), 'assets/logo/apple-touch-icon.png', opaque=True),
             save(sq(64), 'renderer/logo/khayt-mark.png')]

    # ── Marketing site ──────────────────────────────────────────────────────
    # The two favicons there are declared 16 and 32 and are both actually 64.
    site = 'khayt-website'
    made += [save(sq(16), f'{site}/khayt-favicon-16.png'),
             save(sq(32), f'{site}/khayt-favicon-32.png'),
             # apple-touch-icon is 180 and opaque: iOS composites alpha onto black.
             save(sq(180), f'{site}/khayt-apple-icon.png', opaque=True),
             save(sq(256), f'{site}/khayt-icon.png'),
             save(band(lockup, 1200, 630), f'{site}/og-image.png')]
    p = os.path.join(OUT, site, 'favicon.ico')
    os.makedirs(os.path.dirname(p), exist_ok=True)
    sq(48).save(p, sizes=[(16, 16), (32, 32), (48, 48)])
    made.append(f'{site}/favicon.ico')

    # ── PWA icons: the LAN companion and the cloud mobile pages ─────────────
    # lan-server.js currently serves one 1024 PNG for both the 192 and the 512
    # the manifest declares. A maskable icon needs the art inside the safe
    # circle, so it is inset further and the ground fills the rest.
    for px in (192, 512):
        made.append(save(sq(px), f'assets/pwa/icon-{px}.png'))
    made.append(save(compose(512, fg, small, inset=.58), 'assets/pwa/icon-maskable-512.png'))

    print(f'{len(set(made))} files written under {OUT}/')
    for rel in sorted(set(made)):
        print('  ', rel)


if __name__ == '__main__':
    main()
